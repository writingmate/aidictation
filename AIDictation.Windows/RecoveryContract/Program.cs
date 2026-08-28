using System.Net;
using System.Net.Http.Headers;
using System.Text.Json.Nodes;
using AIDictation.Services;

static class Contract
{
    private static int _assertions;

    public static async Task Main()
    {
        await VerifyHttpMatrixAsync();
        await VerifySequentialBulkAsync();
        await VerifyCloudBulkCleanupAsync();
        VerifyStrictResponses();
        VerifyStrictWaveContainers();
        await VerifyNativeCloseRegistryAsync();
        VerifyManagedWorkspaceCleanup();
        await VerifyDurableStoreAsync();
        await VerifyFinalizedAdoptionRecoveryAsync();
        await VerifyDeferredDeletedCleanupAsync();
        await VerifyCleanupFallbacksAsync();
        await VerifyBlockedExporterAsync();
        VerifyTerminalResetFence();
        await VerifyCapturedContextAndGenerationResetAsync();
        await VerifyCoordinatorDeadlineRacesAsync();
        Console.WriteLine($"PASS: Windows audio recovery contract ({_assertions} assertions)");
    }

    private static void VerifyTerminalResetFence()
    {
        var fence = new TerminalStateResetFence<string>();
        var firstResult = fence.Arm("Result");
        fence.Disarm();
        True(!fence.TryConsume(firstResult, "Result"),
            "an old terminal reset cannot consume after a nonterminal transition");

        var firstError = fence.Arm("Error");
        var newerError = fence.Arm("Error");
        True(!fence.TryConsume(firstError, "Error"),
            "re-arming a terminal reset fences the older timer generation");
        True(!fence.TryConsume(newerError, "Recording"),
            "a terminal reset cannot consume a newer nonterminal state");
        True(!fence.TryConsume(newerError, "Error"),
            "a terminal timer is invalidated after observing a different state");

        var currentResult = fence.Arm("Result");
        True(fence.TryConsume(currentResult, "Result"),
            "the current terminal generation resets exactly once");
        True(!fence.TryConsume(currentResult, "Result"),
            "a consumed terminal reset cannot fire twice");
    }

    private static async Task VerifyHttpMatrixAsync()
    {
        var permanent = new[]
        {
            HttpStatusCode.BadRequest,
            HttpStatusCode.Unauthorized,
            HttpStatusCode.Forbidden,
            HttpStatusCode.NotFound,
            HttpStatusCode.Conflict,
            HttpStatusCode.UnprocessableEntity
        };
        foreach (var status in permanent)
        {
            var calls = 0;
            var policy = NoWaitPolicy();
            await ThrowsAsync<AudioRequestException>(() => policy.ExecuteAsync(
                _ =>
                {
                    calls++;
                    return Task.FromResult(Response(status, "permanent"));
                },
                TimeSpan.FromSeconds(1),
                CancellationToken.None));
            Equal(1, calls, $"{(int)status} is attempted once");
        }

        for (var code = 400; code <= 499; code++)
        {
            if (code is 408 or 413 or 429) continue;
            var calls = 0;
            var started = DateTime.UtcNow;
            await ThrowsAsync<AudioRequestException>(() => NoWaitPolicy().ExecuteAsync(
                _ =>
                {
                    calls++;
                    return Task.FromResult(new HttpResponseMessage((HttpStatusCode)code)
                    {
                        Content = new BlockingContent()
                    });
                },
                TimeSpan.FromMinutes(1),
                CancellationToken.None));
            Equal(1, calls, $"{code} is exhaustively permanent and one-shot");
            True(DateTime.UtcNow - started < TimeSpan.FromMilliseconds(500),
                $"{code} is classified from headers without draining a stalled body");
        }

        foreach (var code in new[] { 408, 429, 500 })
        {
            var calls = 0;
            var stalledDelays = new List<TimeSpan>();
            var policy = new AudioHttpRecoveryPolicy((delay, _) =>
            {
                stalledDelays.Add(delay);
                return Task.CompletedTask;
            });
            var started = DateTime.UtcNow;
            await ThrowsAsync<AudioRequestException>(() => policy.ExecuteAsync(
                _ =>
                {
                    calls++;
                    var response = new HttpResponseMessage((HttpStatusCode)code)
                    {
                        Content = new BlockingContent()
                    };
                    if (code is 429 or 500)
                        response.Headers.TryAddWithoutValidation("rEtRy-AfTeR", "7");
                    return Task.FromResult(response);
                },
                TimeSpan.FromMinutes(1),
                CancellationToken.None));
            Equal(3, calls, $"{code} stalled bodies do not change the bounded retry count");
            True(DateTime.UtcNow - started < TimeSpan.FromMilliseconds(500),
                $"{code} retry headers are classified without draining stalled bodies");
            if (code is 429 or 500)
                True(stalledDelays.All(delay => delay == TimeSpan.FromSeconds(7)),
                    $"{code} preserves mixed-case Retry-After before discarding the body");
        }

        {
            var calls = 0;
            await ThrowsAsync<AudioPayloadTooLargeException>(() => NoWaitPolicy().ExecuteAsync(
                _ =>
                {
                    calls++;
                    return Task.FromResult(new HttpResponseMessage(HttpStatusCode.RequestEntityTooLarge)
                    {
                        Content = new BlockingContent()
                    });
                },
                TimeSpan.FromMinutes(1),
                CancellationToken.None));
            Equal(1, calls, "413 splits immediately without draining a stalled body");
        }

        foreach (var status in new[] { HttpStatusCode.Accepted, HttpStatusCode.PartialContent })
        {
            var calls = 0;
            await ThrowsAsync<AudioRequestException>(() => NoWaitPolicy().ExecuteAsync(
                _ =>
                {
                    calls++;
                    return Task.FromResult(Response(status, "not a complete transcription"));
                },
                TimeSpan.FromSeconds(1),
                CancellationToken.None));
            Equal(1, calls, $"{(int)status} is never accepted as a complete transcription");
        }

        var permanentBodyCalls = 0;
        await ThrowsAsync<AudioRequestException>(() => NoWaitPolicy().ExecuteAsync(
            _ =>
            {
                permanentBodyCalls++;
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.BadRequest)
                {
                    Content = new DisconnectingContent()
                });
            },
            TimeSpan.FromSeconds(1),
            CancellationToken.None));
        Equal(1, permanentBodyCalls, "permanent 4xx remains one-shot when its error body disconnects");

        var thrownClientCalls = 0;
        await ThrowsAsync<AudioRequestException>(() => NoWaitPolicy().ExecuteAsync(
            _ =>
            {
                thrownClientCalls++;
                throw new HttpRequestException("unauthorized", null, HttpStatusCode.Unauthorized);
            },
            TimeSpan.FromSeconds(1),
            CancellationToken.None));
        Equal(1, thrownClientCalls, "typed permanent HttpRequestException is not retried");

        foreach (var status in new[]
                 {
                     HttpStatusCode.RequestTimeout,
                     (HttpStatusCode)429,
                     HttpStatusCode.InternalServerError,
                     HttpStatusCode.ServiceUnavailable
                 })
        {
            var calls = 0;
            var response = await NoWaitPolicy().ExecuteAsync(
                _ =>
                {
                    calls++;
                    return Task.FromResult(calls < 3 ? Response(status, "retry") : Response(HttpStatusCode.OK, "ok"));
                },
                TimeSpan.FromSeconds(1),
                CancellationToken.None);
            Equal("ok", response.Body, $"{(int)status} eventually succeeds");
            Equal(3, calls, $"{(int)status} is bounded to three attempts");
        }

        var delays = new List<TimeSpan>();
        var rateCalls = 0;
        var ratePolicy = new AudioHttpRecoveryPolicy((delay, _) =>
        {
            delays.Add(delay);
            return Task.CompletedTask;
        });
        await ratePolicy.ExecuteAsync(
            _ =>
            {
                rateCalls++;
                var response = rateCalls == 1
                    ? Response((HttpStatusCode)429, "busy")
                    : Response(HttpStatusCode.OK, "ok");
                if (rateCalls == 1)
                    response.Headers.RetryAfter = new RetryConditionHeaderValue(TimeSpan.FromSeconds(90));
                return Task.FromResult(response);
            },
            TimeSpan.FromSeconds(1),
            CancellationToken.None);
        Equal(TimeSpan.FromSeconds(10), delays.Single(), "Retry-After is capped at ten seconds");

        var transportCalls = 0;
        var transportResult = await NoWaitPolicy().ExecuteAsync(
            _ =>
            {
                transportCalls++;
                if (transportCalls < 3) throw new HttpRequestException("connect failed");
                return Task.FromResult(Response(HttpStatusCode.OK, "connected"));
            },
            TimeSpan.FromSeconds(1),
            CancellationToken.None);
        Equal("connected", transportResult.Body, "connection failure retries current request");
        Equal(3, transportCalls, "connection retries are bounded");

        var timeoutCalls = 0;
        await ThrowsAsync<AudioRequestException>(() => NoWaitPolicy().ExecuteAsync(
            _ =>
            {
                timeoutCalls++;
                throw new OperationCanceledException("request deadline");
            },
            TimeSpan.FromMilliseconds(1),
            CancellationToken.None));
        Equal(3, timeoutCalls, "request timeout retries at most three times");

        var ignoredSendCalls = 0;
        var ignoredSends = new List<TaskCompletionSource<HttpResponseMessage>>();
        var ignoredStarted = DateTime.UtcNow;
        await ThrowsAsync<AudioRequestException>(() => NoWaitPolicy().ExecuteAsync(
            _ =>
            {
                ignoredSendCalls++;
                var pending = new TaskCompletionSource<HttpResponseMessage>(
                    TaskCreationOptions.RunContinuationsAsynchronously);
                ignoredSends.Add(pending);
                return pending.Task;
            },
            TimeSpan.FromMilliseconds(20),
            CancellationToken.None));
        Equal(3, ignoredSendCalls,
            "transport that ignores cancellation still reaches exactly three request deadlines");
        True(DateTime.UtcNow - ignoredStarted < TimeSpan.FromMilliseconds(500),
            "request deadlines are armed outside a transport that ignores cancellation");
        foreach (var pending in ignoredSends)
            pending.TrySetResult(Response(HttpStatusCode.OK, "late"));

        var ignoredBodyCalls = 0;
        var ignoredBodies = new List<BlockingContent>();
        await ThrowsAsync<AudioRequestException>(() => NoWaitPolicy().ExecuteAsync(
            _ =>
            {
                ignoredBodyCalls++;
                var content = new BlockingContent();
                ignoredBodies.Add(content);
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK) { Content = content });
            },
            TimeSpan.FromMilliseconds(20),
            CancellationToken.None));
        Equal(3, ignoredBodyCalls,
            "response body that ignores cancellation is retried only within the bounded policy");
        foreach (var body in ignoredBodies) body.Release();

        var bodyCalls = 0;
        var bodyResult = await NoWaitPolicy().ExecuteAsync(
            _ =>
            {
                bodyCalls++;
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = bodyCalls < 3
                        ? new DisconnectingContent()
                        : new StringContent("complete")
                });
            },
            TimeSpan.FromSeconds(1),
            CancellationToken.None);
        Equal("complete", bodyResult.Body, "successful-header body disconnect retries");
        Equal(3, bodyCalls, "body drain retries are bounded");

        var malformedCalls = 0;
        var malformed = await NoWaitPolicy().ExecuteAsync(
            _ =>
            {
                malformedCalls++;
                var response = Response(HttpStatusCode.OK, "{\"unexpected\":true}");
                response.Content.Headers.ContentType =
                    new MediaTypeHeaderValue("application/json");
                return Task.FromResult(response);
            },
            TimeSpan.FromSeconds(1),
            CancellationToken.None);
        Throws<InvalidAudioResponseException>(() =>
            AudioTranscriptionResponseParser.ParseCompleteText(
                malformed.Body,
                malformed.MediaType));
        Equal(1, malformedCalls,
            "fully received malformed 200 is parsed once and never retried as transport");

        var oversizedDeclaredCalls = 0;
        await ThrowsAsync<InvalidAudioResponseException>(() => NoWaitPolicy().ExecuteAsync(
            _ =>
            {
                oversizedDeclaredCalls++;
                var content = new ByteArrayContent(
                    new byte[BoundedHttpContentReader.MaxResponseBytes + 1]);
                content.Headers.ContentLength =
                    BoundedHttpContentReader.MaxResponseBytes + 1;
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = content
                });
            },
            TimeSpan.FromSeconds(1),
            CancellationToken.None));
        Equal(1, oversizedDeclaredCalls,
            "oversized successful transcription Content-Length fails permanently without replay");

        var oversizedChunkedCalls = 0;
        await ThrowsAsync<InvalidAudioResponseException>(() => NoWaitPolicy().ExecuteAsync(
            _ =>
            {
                oversizedChunkedCalls++;
                var content = new StreamContent(new RepeatingReadStream(
                    BoundedHttpContentReader.MaxResponseBytes + 1));
                content.Headers.ContentLength = null;
                return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
                {
                    Content = content
                });
            },
            TimeSpan.FromSeconds(1),
            CancellationToken.None));
        Equal(1, oversizedChunkedCalls,
            "oversized chunked transcription is capped while streaming and never replayed");

        var cancellationCalls = 0;
        using var cancellation = new CancellationTokenSource();
        await ThrowsAsync<OperationCanceledException>(async () =>
        {
            var task = NoWaitPolicy().ExecuteAsync(
                async token =>
                {
                    cancellationCalls++;
                    await Task.Delay(Timeout.InfiniteTimeSpan, token);
                    return Response(HttpStatusCode.OK, "late");
                },
                TimeSpan.FromMinutes(1),
                cancellation.Token);
            while (Volatile.Read(ref cancellationCalls) == 0) await Task.Yield();
            cancellation.Cancel();
            await task;
        });
        Equal(1, cancellationCalls, "cancellation is never retried");

        var tooLargeCalls = 0;
        await ThrowsAsync<AudioPayloadTooLargeException>(() => NoWaitPolicy().ExecuteAsync(
            _ =>
            {
                tooLargeCalls++;
                return Task.FromResult(Response(HttpStatusCode.RequestEntityTooLarge, "large"));
            },
            TimeSpan.FromSeconds(1),
            CancellationToken.None));
        Equal(1, tooLargeCalls, "413 is handed to the leaf splitter without retry");
    }

    private static async Task VerifySequentialBulkAsync()
    {
        var calls = new List<string>();
        var checkpoints = new List<string>();
        var runner = new SequentialAudioLeafProcessor<string>();
        var merged = await runner.ProcessAsync(
            new[] { "root" },
            (leaf, _) =>
            {
                calls.Add(leaf);
                if (leaf is "root" or "left") throw new AudioPayloadTooLargeException("split");
                return Task.FromResult(leaf.ToUpperInvariant());
            },
            (leaf, _) => Task.FromResult<IReadOnlyList<string>>(leaf switch
            {
                "root" => new[] { "left", "right" },
                "left" => new[] { "left-a", "left-b" },
                _ => Array.Empty<string>()
            }),
            (text, _, _) =>
            {
                checkpoints.Add(text);
                return Task.FromResult(true);
            },
            CancellationToken.None);
        Equal("LEFT-A LEFT-B RIGHT", merged, "nested 413 leaves preserve order");
        SequenceEqual(new[] { "root", "left", "left-a", "left-b", "right" }, calls,
            "only rejected leaves split and completed leaves are not replayed");
        SequenceEqual(new[] { "LEFT-A", "LEFT-A LEFT-B", "LEFT-A LEFT-B RIGHT" }, checkpoints,
            "every completed leaf persists an ordered checkpoint");

        calls.Clear();
        checkpoints.Clear();
        await ThrowsAsync<AudioRequestException>(() => runner.ProcessAsync(
            new[] { "one", "two", "three" },
            (leaf, _) =>
            {
                calls.Add(leaf);
                return leaf == "two"
                    ? throw new AudioRequestException("permanent")
                    : Task.FromResult(leaf);
            },
            (_, _) => Task.FromResult<IReadOnlyList<string>>(Array.Empty<string>()),
            (text, _, _) =>
            {
                checkpoints.Add(text);
                return Task.FromResult(true);
            },
            CancellationToken.None));
        SequenceEqual(new[] { "one", "two" }, calls, "later leaves are not sent after failure");
        SequenceEqual(new[] { "one" }, checkpoints, "earlier checkpoint survives later failure");

        var checkpointCalls = 0;
        calls.Clear();
        await ThrowsAsync<AudioStoreException>(() => runner.ProcessAsync(
            new[] { "one", "two" },
            (leaf, _) => { calls.Add(leaf); return Task.FromResult(leaf); },
            (_, _) => Task.FromResult<IReadOnlyList<string>>(Array.Empty<string>()),
            (_, _, _) => Task.FromResult(++checkpointCalls != 1),
            CancellationToken.None));
        SequenceEqual(new[] { "one" }, calls, "checkpoint storage failure stops before later leaves");
    }

    private static async Task VerifyCloudBulkCleanupAsync()
    {
        var uploadCalls = new List<string>();
        var checkpoints = new List<string>();
        var processor = new CloudAudioLeafProcessor<string>();
        var recognition = await processor.ProcessAsync(
            new[] { "root" },
            (leaf, allowOneStageCleanup, _) =>
            {
                uploadCalls.Add($"{leaf}:{allowOneStageCleanup}");
                if (leaf is "root" or "left")
                    throw new AudioPayloadTooLargeException("split");
                return Task.FromResult(leaf.ToUpperInvariant());
            },
            (leaf, _) => Task.FromResult<IReadOnlyList<string>>(leaf switch
            {
                "root" => new[] { "left", "right" },
                "left" => new[] { "left-a", "left-b" },
                _ => Array.Empty<string>()
            }),
            (text, _, _) =>
            {
                checkpoints.Add(text);
                return Task.FromResult(true);
            },
            CancellationToken.None);

        Equal("LEFT-A LEFT-B RIGHT", recognition.Text,
            "nested 413 cloud recognition preserves the complete raw transcript");
        True(recognition.RequiresGenericCleanup,
            "a 413 split switches the cloud attempt to one generic cleanup");
        SequenceEqual(
            new[] { "root:True", "left:False", "left-a:False", "left-b:False", "right:False" },
            uploadCalls,
            "413 descendants are raw leaves and never receive per-leaf cleanup");
        SequenceEqual(
            new[] { "LEFT-A", "LEFT-A LEFT-B", "LEFT-A LEFT-B RIGHT" },
            checkpoints,
            "raw nested-413 leaves checkpoint strictly in source order");

        var cleanupCalls = 0;
        var cleaned = await CloudGenericCleanupPolicy.ApplyAsync(
            recognition,
            cleanupEnabled: true,
            (raw, _) =>
            {
                cleanupCalls++;
                Equal("LEFT-A LEFT-B RIGHT", raw,
                    "generic cleanup receives the complete merged raw transcript");
                return Task.FromResult("cleaned once");
            },
            CancellationToken.None);
        Equal("cleaned once", cleaned, "complete generic cleanup may replace merged raw text");
        Equal(1, cleanupCalls, "nested 413 runs generic cleanup exactly once");

        cleanupCalls = 0;
        var emptyFallback = await CloudGenericCleanupPolicy.ApplyAsync(
            recognition,
            cleanupEnabled: true,
            (_, _) =>
            {
                cleanupCalls++;
                return Task.FromResult("  ");
            },
            CancellationToken.None);
        Equal(recognition.Text, emptyFallback, "empty generic cleanup keeps complete raw text");
        Equal(1, cleanupCalls, "empty cleanup is attempted only once");

        var failureFallback = await CloudGenericCleanupPolicy.ApplyAsync(
            recognition,
            cleanupEnabled: true,
            (_, _) => throw new HttpRequestException("cleanup failed"),
            CancellationToken.None);
        Equal(recognition.Text, failureFallback, "generic cleanup failure keeps complete raw text");

        uploadCalls.Clear();
        var initialBulk = await processor.ProcessAsync(
            new[] { "one", "two" },
            (leaf, allowOneStageCleanup, _) =>
            {
                uploadCalls.Add($"{leaf}:{allowOneStageCleanup}");
                return Task.FromResult(leaf.ToUpperInvariant());
            },
            (_, _) => Task.FromResult<IReadOnlyList<string>>(Array.Empty<string>()),
            (_, _, _) => Task.FromResult(true),
            CancellationToken.None);
        True(initialBulk.RequiresGenericCleanup,
            "initial cloud bulk schedules one cleanup after all leaves complete");
        SequenceEqual(new[] { "one:False", "two:False" }, uploadCalls,
            "initial cloud bulk never sends cleanup to individual leaves");

        var singleCleanupCalls = 0;
        var single = await processor.ProcessAsync(
            new[] { "single" },
            (_, allowOneStageCleanup, _) =>
            {
                True(allowOneStageCleanup, "single cloud leaf may retain one-stage cleanup");
                return Task.FromResult("one-stage result");
            },
            (_, _) => Task.FromResult<IReadOnlyList<string>>(Array.Empty<string>()),
            (_, _, _) => Task.FromResult(true),
            CancellationToken.None);
        var singleFinal = await CloudGenericCleanupPolicy.ApplyAsync(
            single,
            cleanupEnabled: true,
            (_, _) =>
            {
                singleCleanupCalls++;
                return Task.FromResult("must not run");
            },
            CancellationToken.None);
        Equal("one-stage result", singleFinal,
            "single-leaf one-stage result is not cleaned a second time");
        Equal(0, singleCleanupCalls, "single-leaf one-stage cleanup is not duplicated");
    }

    private static void VerifyStrictResponses()
    {
        Equal("{\"text\":\"dictated JSON\"}",
            AudioTranscriptionResponseParser.ParseCompleteText("{\"text\":\"dictated JSON\"}", "text/plain"),
            "text responses that look like JSON remain literal");
        Equal("hello",
            AudioTranscriptionResponseParser.ParseCompleteText("{\"text\":\"hello\"}", "application/json"),
            "complete single-field JSON envelope unwraps");
        Throws<InvalidAudioResponseException>(() =>
            AudioTranscriptionResponseParser.ParseCompleteText("", "text/plain"));
        Throws<InvalidAudioResponseException>(() =>
            AudioTranscriptionResponseParser.ParseCompleteText("{broken", "application/json"));
        Throws<InvalidAudioResponseException>(() =>
            AudioTranscriptionResponseParser.ParseCompleteText("{\"text\":\"ok\",\"extra\":1}", "application/json"));
        Throws<InvalidAudioResponseException>(() =>
            AudioTranscriptionResponseParser.ParseCompleteText("[]", "application/json"));
    }

    private static void VerifyStrictWaveContainers()
    {
        var root = Path.Combine(Path.GetTempPath(), $"aidictation-wave-contract-{Guid.NewGuid():N}");
        Directory.CreateDirectory(root);
        try
        {
            var valid = Path.Combine(root, "valid.wav");
            WriteWave(valid, 2_048);
            True(AudioContainerValidator.ValidateFinalizedWave(valid).IsValid,
                "closed aligned WAVE passes strict validation");

            var truncated = Path.Combine(root, "truncated.wav");
            File.Copy(valid, truncated);
            using (var stream = new FileStream(truncated, FileMode.Open, FileAccess.Write, FileShare.None))
                stream.SetLength(stream.Length - 1);
            True(!AudioContainerValidator.ValidateFinalizedWave(truncated).IsValid,
                "truncated RIFF length is rejected");

            var empty = Path.Combine(root, "empty.wav");
            WriteWave(empty, 0);
            True(!AudioContainerValidator.ValidateFinalizedWave(empty).IsValid,
                "zero-length audio data is rejected");

            var misaligned = Path.Combine(root, "misaligned.wav");
            WriteWave(misaligned, 3);
            True(!AudioContainerValidator.ValidateFinalizedWave(misaligned).IsValid,
                "partial PCM frames are rejected");

            var invalidRate = Path.Combine(root, "invalid-rate.wav");
            File.Copy(valid, invalidRate);
            using (var stream = new FileStream(invalidRate, FileMode.Open, FileAccess.Write, FileShare.None))
            using (var writer = new BinaryWriter(stream))
            {
                stream.Position = 28;
                writer.Write((uint)1);
                writer.Flush();
                stream.Flush(flushToDisk: true);
            }
            True(!AudioContainerValidator.ValidateFinalizedWave(invalidRate).IsValid,
                "inconsistent WAVE byte rate is rejected");
        }
        finally
        {
            try { Directory.Delete(root, recursive: true); } catch { }
        }
    }

    private static async Task VerifyNativeCloseRegistryAsync()
    {
        var registry = new RetiredNativeCloseRegistry<object>();
        var resource = new object();
        True(registry.TryInstall(resource), "native close registry installs one current owner");
        var shutdown = registry.BeginShutdown();
        True(!registry.HasCurrent,
            "shutdown atomically removes current ownership");
        True(shutdown.Current is { OwnsClose: true },
            "shutdown receives close ownership for the current native resource");
        Equal(1, shutdown.CloseTasks.Count,
            "current-to-retired transfer is visible in the same shutdown snapshot");
        True(!shutdown.CloseTasks[0].IsCompleted,
            "retired close remains owned during the deterministic transfer gap");
        Equal(1, registry.SnapshotCloseTasks().Count,
            "a concurrent exit observer cannot see neither current nor retired ownership");
        registry.Complete(resource);
        await shutdown.CloseTasks[0].WaitAsync(TimeSpan.FromSeconds(1));
        Equal(0, registry.SnapshotCloseTasks().Count,
            "completed retired close leaves the bounded registry exactly once");
        True(!registry.TryInstall(new object()),
            "shutdown permanently fences a late native capture installation");
    }

    private static void VerifyManagedWorkspaceCleanup()
    {
        var anchor = Path.Combine(
            Path.GetTempPath(),
            $"aidictation-workspace-anchor-{Guid.NewGuid():N}");
        var workspaces = Path.Combine(anchor, "Workspaces");
        var outside = Path.Combine(
            Path.GetTempPath(),
            $"aidictation-workspace-outside-{Guid.NewGuid():N}");
        Directory.CreateDirectory(anchor);
        Directory.CreateDirectory(outside);
        var sentinel = Path.Combine(outside, "sentinel.txt");
        File.WriteAllText(sentinel, "keep");
        try
        {
            using (var workspace = ManagedAudioWorkspace.Create(anchor, workspaces, "upload"))
            {
                File.WriteAllText(workspace.FilePath("leaf.wav"), "temporary");
                var linkedFile = workspace.FilePath("outside-link.wav");
                File.CreateSymbolicLink(linkedFile, sentinel);
            }
            Equal("keep", File.ReadAllText(sentinel),
                "workspace cleanup deletes a file link without following it");

            var danglingTarget = Path.Combine(outside, "missing");
            var dangling = Path.Combine(workspaces, $"upload-{Guid.NewGuid():N}");
            Directory.CreateSymbolicLink(dangling, danglingTarget);
            ManagedAudioWorkspace.Sweep(anchor, workspaces);
            True(!Directory.Exists(dangling) &&
                 !ManagedAudioPathPolicy.EntryExistsNoFollow(dangling),
                "workspace sweep removes a dangling directory link without creating its target");
            True(!Directory.Exists(danglingTarget),
                "dangling workspace cleanup never materializes an outside target");
        }
        finally
        {
            try { if (Directory.Exists(anchor)) Directory.Delete(anchor, recursive: true); } catch { }
            try { if (Directory.Exists(outside)) Directory.Delete(outside, recursive: true); } catch { }
        }
    }

    private static async Task VerifyDurableStoreAsync()
    {
        var root = Path.Combine(Path.GetTempPath(), $"aidictation-windows-contract-{Guid.NewGuid():N}");
        try
        {
            var now = DateTimeOffset.Parse("2026-07-19T12:00:00Z");
            var legacyRoot = Path.Combine(root, "legacy-recordings");
            Directory.CreateDirectory(legacyRoot);
            var store = new AudioProcessingStore(root, () => now, legacyRoot);
            var cloud = Snapshot("cloud", "cloud-context");

            var interrupted = await store.BeginCaptureAsync(cloud);
            True(interrupted.Applied && interrupted.Lease != null && interrupted.Entry != null,
                "journal allocates stable id before native capture");
            True(File.Exists(interrupted.Entry!.PartialSourcePath), "managed partial source exists before capture");
            var recovered = await new AudioProcessingStore(root, () => now.AddMinutes(1), legacyRoot)
                .RecoverOnLaunchAsync();
            var recoveredInterrupted = recovered.Single(item => item.RecordingId == interrupted.Entry.RecordingId);
            Equal(AudioProcessingStage.Failed, recoveredInterrupted.Stage, "process death normalizes capture to failed");
            Equal(AudioSourceIntegrity.Unfinalized, recoveredInterrupted.SourceIntegrity,
                "interrupted capture is never submitted as complete");
            True(File.Exists(recoveredInterrupted.PartialSourcePath), "startup preserves interrupted source");

            var finalizedBeforeCrash = await store.BeginCaptureAsync(cloud);
            WriteWave(finalizedBeforeCrash.Entry!.PartialSourcePath, 2_048);
            var finalizedReady = await store.CaptureBecameReadyAsync(finalizedBeforeCrash.Lease!);
            var finalizedStage = await store.BeginFinalizationAsync(finalizedReady.Lease!);
            var legacyFinalizationJournalPath = Path.Combine(root, "journal.json");
            var legacyFinalizationJournal = JsonNode.Parse(
                await File.ReadAllTextAsync(legacyFinalizationJournalPath))!.AsObject();
            var legacyFinalizationEntry = legacyFinalizationJournal["Entries"]!.AsObject()
                .Single(pair => Guid.Parse(pair.Key) == finalizedBeforeCrash.Entry.RecordingId)
                .Value!.AsObject();
            legacyFinalizationEntry["FinalizationStarted"] = true;
            _ = legacyFinalizationEntry.Remove("FinalizationProven");
            await File.WriteAllTextAsync(
                legacyFinalizationJournalPath,
                legacyFinalizationJournal.ToJsonString());
            var recoveredFinalization = (await new AudioProcessingStore(root, () => now.AddMinutes(1), legacyRoot)
                    .RecoverOnLaunchAsync())
                .Single(item => item.RecordingId == finalizedBeforeCrash.Entry.RecordingId);
            Equal(AudioProcessingStage.Failed, recoveredFinalization.Stage,
                "interrupted finalization returns as a terminal preserved row");
            Equal(AudioSourceIntegrity.Unfinalized, recoveredFinalization.SourceIntegrity,
                "close intent without positive recorder proof is never promoted");
            True(File.Exists(recoveredFinalization.PartialSourcePath),
                "startup preserves an unproven partial source without submitting it");
            True(!File.Exists(recoveredFinalization.FinalSourcePath),
                "startup does not manufacture completion from a structurally valid prefix");

            var legacyMovedBeforeJournal = await store.BeginCaptureAsync(cloud);
            WriteWave(legacyMovedBeforeJournal.Entry!.PartialSourcePath, 2_048);
            var legacyMovedReady = await store.CaptureBecameReadyAsync(
                legacyMovedBeforeJournal.Lease!);
            _ = await store.BeginFinalizationAsync(legacyMovedReady.Lease!);
            File.Move(
                legacyMovedBeforeJournal.Entry.PartialSourcePath,
                legacyMovedBeforeJournal.Entry.FinalSourcePath);
            var legacyMovedJournal = JsonNode.Parse(
                await File.ReadAllTextAsync(legacyFinalizationJournalPath))!.AsObject();
            var legacyMovedEntry = legacyMovedJournal["Entries"]!.AsObject()
                .Single(pair => Guid.Parse(pair.Key) == legacyMovedBeforeJournal.Entry.RecordingId)
                .Value!.AsObject();
            legacyMovedEntry["FinalizationStarted"] = true;
            _ = legacyMovedEntry.Remove("FinalizationProven");
            await File.WriteAllTextAsync(
                legacyFinalizationJournalPath,
                legacyMovedJournal.ToJsonString());
            var recoveredLegacyMoved = (await new AudioProcessingStore(
                    root,
                    () => now.AddMinutes(1),
                    legacyRoot).RecoverOnLaunchAsync())
                .Single(item => item.RecordingId == legacyMovedBeforeJournal.Entry.RecordingId);
            Equal(AudioSourceIntegrity.Complete, recoveredLegacyMoved.SourceIntegrity,
                "an old journal still recovers a valid source already atomically moved to final");

            var closedAfterTerminal = await store.BeginCaptureAsync(cloud);
            var closedAfterTerminalReady = await store.CaptureBecameReadyAsync(closedAfterTerminal.Lease!);
            var closedAfterTerminalFinalizing = await store.BeginFinalizationAsync(closedAfterTerminalReady.Lease!);
            var terminalBeforeClose = await store.AbandonAttemptAsync(
                closedAfterTerminalFinalizing.Lease!,
                false,
                "finalization timed out before native close",
                AudioSourceIntegrity.Unfinalized);
            Equal(AudioSourceIntegrity.Unfinalized, terminalBeforeClose.Entry!.SourceIntegrity,
                "a terminal row does not claim completeness before native close finishes");
            WriteWave(terminalBeforeClose.Entry.PartialSourcePath, 2_048);
            var recoveredTerminalClose = (await new AudioProcessingStore(
                    root,
                    () => now.AddMinutes(1),
                    legacyRoot).RecoverOnLaunchAsync())
                .Single(item => item.RecordingId == closedAfterTerminal.Entry!.RecordingId);
            Equal(AudioProcessingStage.Failed, recoveredTerminalClose.Stage,
                "late native close keeps the already-terminal failure state");
            Equal(AudioSourceIntegrity.Unfinalized, recoveredTerminalClose.SourceIntegrity,
                "launch never promotes a late close without authoritative recorder proof");
            True(File.Exists(recoveredTerminalClose.PartialSourcePath) &&
                 !File.Exists(recoveredTerminalClose.FinalSourcePath),
                "late-closed but unproven source remains preserved and non-promotable");
            var rejectedUnprovenRetry = await store.BeginRecognitionAsync(
                closedAfterTerminal.Entry!.RecordingId,
                cloud);
            True(!rejectedUnprovenRetry.Applied,
                "an unproven late close cannot be submitted for recognition");
            var latePositive = await store.AdoptFinalizedCaptureAsync(
                terminalBeforeClose.Lease!,
                new RecorderFinalizationResult(
                    true,
                    recoveredTerminalClose.PartialSourcePath,
                    null));
            True(latePositive.Applied &&
                 latePositive.Entry?.SourceIntegrity == AudioSourceIntegrity.Complete,
                "an exact late positive recorder proof makes the terminal source retryable");
            var recoveredTerminalRetry = await store.BeginRecognitionAsync(
                closedAfterTerminal.Entry!.RecordingId,
                cloud);
            True(recoveredTerminalRetry.Applied,
                "a terminal failure becomes retryable only after positive proof is persisted");
            _ = await store.FailAsync(
                recoveredTerminalRetry.Lease!,
                "test cleanup",
                AudioSourceIntegrity.Complete);

            var full = await store.BeginCaptureAsync(cloud);
            var captureLease = full.Lease!;
            WriteWave(full.Entry!.PartialSourcePath, 4_096);
            var ready = await store.CaptureBecameReadyAsync(captureLease);
            True(ready.Applied, "first-write readiness advances journal");
            var finalizing = await store.BeginFinalizationAsync(ready.Lease!);
            True(finalizing.Applied, "finalization has durable stage");
            var accepted = await store.AdoptFinalizedCaptureAsync(
                finalizing.Lease!,
                new RecorderFinalizationResult(
                    true,
                    finalizing.Entry!.PartialSourcePath,
                    null));
            Equal(AudioProcessingStage.ReadyForRecognition, accepted.Entry!.Stage,
                "closed non-empty WAVE is accepted before recognition");
            True(File.Exists(accepted.Entry.FinalSourcePath), "final source is atomically promoted");
            True(!File.Exists(accepted.Entry.PartialSourcePath), "promotion leaves one managed source");

            var latePromotion = await store.BeginCaptureAsync(cloud);
            WriteWave(latePromotion.Entry!.PartialSourcePath, 2_048);
            var lateReady = await store.CaptureBecameReadyAsync(latePromotion.Lease!);
            var lateFinalizing = await store.BeginFinalizationAsync(lateReady.Lease!);
            var lateAccepted = await store.AdoptFinalizedCaptureAsync(
                lateFinalizing.Lease!,
                new RecorderFinalizationResult(
                    true,
                    lateFinalizing.Entry!.PartialSourcePath,
                    null));
            var lateAbandoned = await store.AbandonAttemptAsync(
                lateFinalizing.Lease!,
                false,
                "caller timed out before seeing promotion",
                AudioSourceIntegrity.Unfinalized);
            True(lateAccepted.Applied && lateAbandoned.Applied,
                "late final-source promotion is reconciled by terminal abandonment");
            Equal(AudioSourceIntegrity.Complete, lateAbandoned.Entry!.SourceIntegrity,
                "stale pre-promotion integrity cannot downgrade a validated managed source");
            var lateRetryStart = await store.BeginRecognitionAsync(latePromotion.Entry.RecordingId, cloud);
            True(lateRetryStart.Applied,
                "late-promoted complete source remains retryable");
            _ = await store.FailAsync(
                lateRetryStart.Lease!,
                "test cleanup",
                AudioSourceIntegrity.Complete);

            var firstRecognition = await store.BeginRecognitionAsync(full.Entry.RecordingId, cloud);
            var competingRecognition = await store.BeginRecognitionAsync(full.Entry.RecordingId, Snapshot("local", "local-context"));
            True(firstRecognition.Applied, "first retry owns stable recording id");
            True(!competingRecognition.Applied, "simultaneous retry cannot steal attempt ownership");
            Equal("cloud", firstRecognition.Entry!.SettingsSnapshot!.Provider,
                "attempt retains its provider snapshot");

            var checkpoint1 = await store.SaveCheckpointAsync(firstRecognition.Lease!, "first", 1);
            var checkpoint2 = await store.SaveCheckpointAsync(checkpoint1.Lease!, "first second", 2);
            Equal("first second", checkpoint2.Entry!.CheckpointText, "ordered checkpoint is durable");
            var raw = await store.SaveRawResultAsync(checkpoint2.Lease!, "first second");
            Equal(AudioProcessingStage.ResultReady, raw.Entry!.Stage, "raw text is durable before cleanup completion");

            var rawRecovery = await new AudioProcessingStore(root, () => now.AddMinutes(2), legacyRoot)
                .RecoverOnLaunchAsync();
            var recoveredRaw = rawRecovery.Single(item => item.RecordingId == full.Entry.RecordingId);
            Equal(AudioProcessingStage.Succeeded, recoveredRaw.Stage,
                "restart promotes complete raw text when optional cleanup was interrupted");
            Equal("first second", recoveredRaw.FinalText, "restart raw fallback preserves complete transcript");
            Equal(UsageAccountingState.Pending, recoveredRaw.UsageAccounting,
                "raw fallback atomically queues durable usage eligibility with success");
            var rawUsage = await store.ClaimUsageAsync(recoveredRaw.RecordingId);
            Equal("first second", rawUsage!.Text,
                "durable raw fallback usage can be claimed once after History publication");
            True(await store.ClaimUsageAsync(recoveredRaw.RecordingId) == null,
                "usage claim is irrevocable before the non-idempotent sink");
            var lateAbandonAfterSuccess = await store.AbandonAttemptAsync(
                raw.Lease!,
                true,
                "late cancellation after durable success",
                AudioSourceIntegrity.Complete);
            True(!lateAbandonAfterSuccess.Applied,
                "late abandonment cannot downgrade a durable successful result");
            Equal(AudioProcessingStage.Succeeded,
                (await store.GetAsync(full.Entry.RecordingId))!.Stage,
                "durable success remains authoritative over late cancellation");

            var retry = await store.BeginRecognitionAsync(full.Entry.RecordingId, Snapshot("local", "local-context"));
            True(retry.Applied, "explicit retry reuses recording id");
            Equal(full.Entry.RecordingId, retry.Entry!.RecordingId, "retry does not duplicate history identity");
            var failed = await store.FailAsync(retry.Lease!, "offline engine failed", AudioSourceIntegrity.Complete);
            Equal(AudioProcessingStage.Failed, failed.Entry!.Stage, "local engine failure becomes terminal");
            Equal("first second", failed.Entry.FinalText,
                "failed retry preserves the previously committed complete transcript");
            True(File.Exists(failed.Entry.FinalSourcePath), "recognition failure preserves only recoverable source");

            var corruptActive = await store.BeginCaptureAsync(cloud);
            WriteWave(corruptActive.Entry!.PartialSourcePath, 2_048);
            var corruptReady = await store.CaptureBecameReadyAsync(corruptActive.Lease!);
            var corruptFinalizing = await store.BeginFinalizationAsync(corruptReady.Lease!);
            var corruptAccepted = await store.AdoptFinalizedCaptureAsync(
                corruptFinalizing.Lease!,
                new RecorderFinalizationResult(
                    true,
                    corruptFinalizing.Entry!.PartialSourcePath,
                    null));
            _ = await store.BeginRecognitionAsync(corruptActive.Entry.RecordingId, cloud);
            using (var corruptFinal = new FileStream(
                       corruptAccepted.Entry!.FinalSourcePath,
                       FileMode.Open,
                       FileAccess.Write,
                       FileShare.None))
                corruptFinal.SetLength(8);
            var recoveredCorruptActive = (await new AudioProcessingStore(
                    root,
                    () => now.AddMinutes(2),
                    legacyRoot).RecoverOnLaunchAsync())
                .Single(entry => entry.RecordingId == corruptActive.Entry.RecordingId);
            Equal(AudioSourceIntegrity.KnownIncomplete, recoveredCorruptActive.SourceIntegrity,
                "launch recovery never labels a corrupt managed final source as complete");
            Equal(AudioProcessingStage.Failed, recoveredCorruptActive.Stage,
                "interrupted recognition with corrupt source becomes terminal and non-retryable");

            var retryForDelete = await store.BeginRecognitionAsync(full.Entry.RecordingId, cloud);
            var checkpointBeforeDelete = await store.SaveCheckpointAsync(retryForDelete.Lease!, "saved", 1);
            var failedForDelete = await store.FailAsync(checkpointBeforeDelete.Lease!, "done", AudioSourceIntegrity.Complete);
            var tombstone = await store.TombstoneAsync(full.Entry.RecordingId);
            True(tombstone.Applied, "terminal delete commits tombstone");
            var staleAfterDelete = await store.SaveCheckpointAsync(failedForDelete.Lease!, "late", 2);
            True(!staleAfterDelete.Applied, "late callback cannot recreate deleted row");
            Equal(AudioProcessingStage.Deleted, (await store.GetAsync(full.Entry.RecordingId))!.Stage,
                "deleted state remains authoritative");

            var clearCandidate = await store.BeginCaptureAsync(Snapshot("local", "second"));
            var clearFailed = await store.FailAsync(clearCandidate.Lease!, "capture write failed", AudioSourceIntegrity.KnownIncomplete);
            var staleClearLease = clearFailed.Lease!;
            var cleared = await store.ClearAsync();
            True(cleared.Applied, "clear commits global deletion generation");
            var staleAfterClear = await store.FailAsync(staleClearLease, "late", AudioSourceIntegrity.KnownIncomplete);
            True(!staleAfterClear.Applied, "global clear generation fences every late callback");

            var legacyPath = Path.Combine(legacyRoot, "recording_20260724_104512.wav");
            WriteWave(legacyPath, 2_048);
            var legacyId = Guid.NewGuid();
            var imported = await store.ImportLegacyFinalizedSourceAsync(
                legacyId,
                legacyPath,
                "legacy transcript",
                Snapshot("cloud", "legacy"));
            True(imported.Applied && imported.Entry != null,
                "shipped recording_yyyyMMdd_HHmmss.wav source migrates into managed storage");
            Equal(AudioProcessingStage.Succeeded, imported.Entry!.Stage, "legacy transcript remains successful");
            True(imported.Entry.UsageAccounting == null,
                "pre-recovery legacy successes are never retroactively billable");
            True(File.Exists(imported.Entry.FinalSourcePath), "legacy migration preserves a managed complete copy");
            True(File.Exists(legacyPath), "legacy source is not deleted before migration consumers update");
            True(imported.Entry.LegacySourceOwned, "app-owned legacy source ownership is journaled");
            True(await store.AcceptLegacySourceOwnershipAsync(legacyId),
                "legacy deletion is accepted only after the History repoint commits");
            True(!File.Exists(legacyPath), "accepted app-owned legacy source is deleted exactly once");

            var malformedLegacyPath = Path.Combine(legacyRoot, "recording_20260724-104512.wav");
            WriteWave(malformedLegacyPath, 2_048);
            var malformedLegacy = await store.ImportLegacyFinalizedSourceAsync(
                Guid.NewGuid(),
                malformedLegacyPath,
                "must not import",
                Snapshot("cloud", "legacy"));
            True(!malformedLegacy.Applied,
                "legacy migration accepts only exact shipped filename shapes");
            True(File.Exists(malformedLegacyPath),
                "a rejected legacy filename is preserved and never deleted");

            var recoveryLegacyPath = Path.Combine(legacyRoot, "recording_2.wav");
            WriteWave(recoveryLegacyPath, 2_048);
            var recoveryLegacyId = Guid.NewGuid();
            var recoveryLegacy = await store.ImportLegacyFinalizedSourceAsync(
                recoveryLegacyId,
                recoveryLegacyPath,
                "keep source",
                Snapshot("cloud", "legacy"));
            using (var corruptManaged = new FileStream(
                       recoveryLegacy.Entry!.FinalSourcePath,
                       FileMode.Open,
                       FileAccess.Write,
                       FileShare.None))
                corruptManaged.SetLength(8);
            True(!await store.AcceptLegacySourceOwnershipAsync(recoveryLegacyId),
                "legacy deletion refuses a missing or corrupt managed replacement");
            True(File.Exists(recoveryLegacyPath),
                "failed managed-copy revalidation preserves the only valid legacy source");
            True((await store.TombstoneAsync(recoveryLegacyId)).Applied,
                "explicit delete can still tombstone a row whose managed copy is corrupt");
            await WaitUntilAsync(
                () => !File.Exists(recoveryLegacyPath),
                TimeSpan.FromSeconds(1));
            True(!File.Exists(recoveryLegacyPath),
                "explicit delete removes the tracked legacy source after its tombstone commits");

            var pendingLegacyPath = Path.Combine(legacyRoot, "recording_3.wav");
            WriteWave(pendingLegacyPath, 2_048);
            var pendingLegacyId = Guid.NewGuid();
            var pendingLegacy = await store.ImportLegacyFinalizedSourceAsync(
                pendingLegacyId,
                pendingLegacyPath,
                "keep pending source",
                Snapshot("cloud", "legacy"));
            var pendingJournalPath = Path.Combine(root, "journal.json");
            var pendingJournal = JsonNode.Parse(await File.ReadAllTextAsync(pendingJournalPath))!.AsObject();
            var pendingSerializedEntry = pendingJournal["Entries"]!.AsObject()
                .Single(pair => Guid.Parse(pair.Key) == pendingLegacyId)
                .Value!.AsObject();
            pendingSerializedEntry["LegacySourceDeletionPending"] = true;
            await File.WriteAllTextAsync(pendingJournalPath, pendingJournal.ToJsonString());
            using (var corruptManaged = new FileStream(
                       pendingLegacy.Entry!.FinalSourcePath,
                       FileMode.Open,
                       FileAccess.Write,
                       FileShare.None))
                corruptManaged.SetLength(8);
            var pendingRecovery = await new AudioProcessingStore(root, () => now.AddMinutes(2), legacyRoot)
                .RecoverOnLaunchAsync();
            True(File.Exists(pendingLegacyPath),
                "launch recovery revalidates the managed copy before resuming pending legacy deletion");
            True(pendingRecovery.Single(entry => entry.RecordingId == pendingLegacyId)
                    .LegacySourceDeletionPending,
                "failed launch revalidation keeps legacy deletion pending for a future safe retry");
            True((await store.TombstoneAsync(pendingLegacyId)).Applied,
                "explicit delete still removes a pending legacy source after recovery refusal");

            var tombstoneLegacyPath = Path.Combine(legacyRoot, "recording_4.wav");
            WriteWave(tombstoneLegacyPath, 2_048);
            var tombstoneLegacyId = Guid.NewGuid();
            var tombstoneLegacy = await store.ImportLegacyFinalizedSourceAsync(
                tombstoneLegacyId,
                tombstoneLegacyPath,
                "delete me",
                Snapshot("cloud", "legacy"));
            True(tombstoneLegacy.Applied, "second owned legacy source is imported");
            True((await store.TombstoneAsync(tombstoneLegacyId)).Applied,
                "tombstone durably wins over an owned legacy source");
            await WaitUntilAsync(
                () => !File.Exists(tombstoneLegacyPath),
                TimeSpan.FromSeconds(1));
            True(!File.Exists(tombstoneLegacyPath), "tombstone deletes the tracked legacy source");

            var clearLegacyPath = Path.Combine(legacyRoot, "recording_5.wav");
            WriteWave(clearLegacyPath, 2_048);
            var clearLegacy = await store.ImportLegacyFinalizedSourceAsync(
                Guid.NewGuid(),
                clearLegacyPath,
                "clear me",
                Snapshot("cloud", "legacy"));
            True(clearLegacy.Applied, "owned legacy source exists before Clear");
            True((await store.ClearAsync()).Applied, "Clear commits before deleting tracked sources");
            await WaitUntilAsync(
                () => !File.Exists(clearLegacyPath),
                TimeSpan.FromSeconds(1));
            True(!File.Exists(clearLegacyPath), "Clear deletes the tracked legacy source");

            var pathOwned = await store.BeginCaptureAsync(cloud);
            var victimPath = Path.Combine(root, "unmanaged-victim.wav");
            WriteWave(victimPath, 1_024);
            var journalPath = Path.Combine(root, "journal.json");
            var journal = JsonNode.Parse(await File.ReadAllTextAsync(journalPath))!.AsObject();
            var serializedEntries = journal["Entries"]!.AsObject();
            var serializedKey = serializedEntries
                .Select(pair => pair.Key)
                .Single(key => Guid.Parse(key) == pathOwned.Entry!.RecordingId);
            var serializedEntry = serializedEntries[serializedKey]!.AsObject();
            serializedEntry["PartialSourcePath"] = victimPath;
            serializedEntry["FinalSourcePath"] = victimPath;
            await File.WriteAllTextAsync(journalPath, journal.ToJsonString());

            var normalizedStore = new AudioProcessingStore(root, () => now.AddMinutes(3), legacyRoot);
            var normalizedEntry = await normalizedStore.GetAsync(pathOwned.Entry!.RecordingId);
            Equal(pathOwned.Entry.PartialSourcePath, normalizedEntry!.PartialSourcePath,
                "journal paths are re-derived from the stable recording id");
            Equal(pathOwned.Entry.FinalSourcePath, normalizedEntry.FinalSourcePath,
                "a serialized final path cannot redirect recognition");
            var normalizedFailed = await normalizedStore.FailAsync(
                pathOwned.Lease!, "test terminal", AudioSourceIntegrity.KnownIncomplete);
            var normalizedDeleted = await normalizedStore.TombstoneAsync(pathOwned.Entry.RecordingId);
            True(normalizedFailed.Applied && normalizedDeleted.Applied,
                "normalized entries still follow terminal deletion transitions");
            True(File.Exists(victimPath), "tombstones never delete a serialized unmanaged path");

            var sourceLinkAnchor = Path.Combine(
                Path.GetTempPath(),
                $"aidictation-source-link-anchor-{Guid.NewGuid():N}");
            var sourceLinkRoot = Path.Combine(sourceLinkAnchor, "AudioProcessing");
            var sourceLinkOutside = Path.Combine(
                Path.GetTempPath(),
                $"aidictation-source-link-outside-{Guid.NewGuid():N}");
            Directory.CreateDirectory(sourceLinkAnchor);
            Directory.CreateDirectory(sourceLinkOutside);
            var sourceLinkSentinel = Path.Combine(sourceLinkOutside, "sentinel.txt");
            await File.WriteAllTextAsync(sourceLinkSentinel, "keep");
            try
            {
                var linkedStore = new AudioProcessingStore(
                    sourceLinkRoot,
                    trustedRootPath: sourceLinkAnchor);
                _ = await linkedStore.RecoverOnLaunchAsync();
                Directory.Delete(Path.Combine(sourceLinkRoot, "Sources"));
                Directory.CreateSymbolicLink(
                    Path.Combine(sourceLinkRoot, "Sources"),
                    sourceLinkOutside);
                await ThrowsAsync<AudioStoreException>(() =>
                    linkedStore.BeginCaptureAsync(cloud));
                Equal("keep", await File.ReadAllTextAsync(sourceLinkSentinel),
                    "live Sources link is rejected before capture can touch outside data");
                await ThrowsAsync<AudioStoreException>(() => linkedStore.ClearAsync());
                Equal("keep", await File.ReadAllTextAsync(sourceLinkSentinel),
                    "Clear fails closed instead of following a live Sources link");
            }
            finally
            {
                try
                {
                    var link = Path.Combine(sourceLinkRoot, "Sources");
                    if (ManagedAudioPathPolicy.EntryExistsNoFollow(link))
                        Directory.Delete(link, recursive: false);
                }
                catch { }
                try { if (Directory.Exists(sourceLinkAnchor)) Directory.Delete(sourceLinkAnchor, true); } catch { }
                try { if (Directory.Exists(sourceLinkOutside)) Directory.Delete(sourceLinkOutside, true); } catch { }
            }

            var danglingAnchor = Path.Combine(
                Path.GetTempPath(),
                $"aidictation-source-dangling-anchor-{Guid.NewGuid():N}");
            var danglingRoot = Path.Combine(danglingAnchor, "AudioProcessing");
            var danglingTarget = Path.Combine(
                Path.GetTempPath(),
                $"aidictation-source-dangling-target-{Guid.NewGuid():N}");
            Directory.CreateDirectory(danglingAnchor);
            Directory.CreateDirectory(danglingRoot);
            Directory.CreateSymbolicLink(
                Path.Combine(danglingRoot, "Sources"),
                danglingTarget);
            try
            {
                var danglingStore = new AudioProcessingStore(
                    danglingRoot,
                    trustedRootPath: danglingAnchor);
                await ThrowsAsync<AudioStoreException>(() =>
                    danglingStore.BeginCaptureAsync(cloud));
                True(!Directory.Exists(danglingTarget),
                    "dangling Sources link is rejected without creating its outside target");
            }
            finally
            {
                try
                {
                    var link = Path.Combine(danglingRoot, "Sources");
                    if (ManagedAudioPathPolicy.EntryExistsNoFollow(link))
                        Directory.Delete(link, recursive: false);
                }
                catch { }
                try { if (Directory.Exists(danglingAnchor)) Directory.Delete(danglingAnchor, true); } catch { }
            }

            var leafAnchor = Path.Combine(
                Path.GetTempPath(),
                $"aidictation-source-leaf-anchor-{Guid.NewGuid():N}");
            var leafRoot = Path.Combine(leafAnchor, "AudioProcessing");
            var leafOutside = Path.Combine(
                Path.GetTempPath(),
                $"aidictation-source-leaf-outside-{Guid.NewGuid():N}.wav");
            Directory.CreateDirectory(leafAnchor);
            WriteWave(leafOutside, 2_048);
            try
            {
                var leafStore = new AudioProcessingStore(
                    leafRoot,
                    trustedRootPath: leafAnchor);
                var leafCapture = await leafStore.BeginCaptureAsync(cloud);
                File.Delete(leafCapture.Entry!.PartialSourcePath);
                File.CreateSymbolicLink(leafCapture.Entry.PartialSourcePath, leafOutside);
                var leafReady = await leafStore.CaptureBecameReadyAsync(leafCapture.Lease!);
                var leafFinalizing = await leafStore.BeginFinalizationAsync(leafReady.Lease!);
                await ThrowsAsync<AudioStoreException>(() =>
                    leafStore.AdoptFinalizedCaptureAsync(
                        leafFinalizing.Lease!,
                        new RecorderFinalizationResult(
                            true,
                            leafFinalizing.Entry!.PartialSourcePath,
                            null)));
                True(AudioContainerValidator.ValidateFinalizedWave(leafOutside).IsValid,
                    "linked source leaf is rejected without moving or truncating its outside target");
            }
            finally
            {
                try
                {
                    var sources = Path.Combine(leafRoot, "Sources");
                    if (Directory.Exists(sources))
                    {
                        foreach (var entry in Directory.EnumerateFileSystemEntries(sources))
                        {
                            if (ManagedAudioPathPolicy.IsReparsePoint(entry)) File.Delete(entry);
                        }
                    }
                }
                catch { }
                try { if (Directory.Exists(leafAnchor)) Directory.Delete(leafAnchor, true); } catch { }
                try { File.Delete(leafOutside); } catch { }
            }

            var corruptRoot = Path.Combine(Path.GetTempPath(), $"aidictation-windows-corrupt-{Guid.NewGuid():N}");
            Directory.CreateDirectory(corruptRoot);
            await File.WriteAllTextAsync(Path.Combine(corruptRoot, "journal.json"), "{broken");
            var corruptStore = new AudioProcessingStore(corruptRoot);
            await ThrowsAsync<AudioStoreException>(() => corruptStore.RecoverOnLaunchAsync());
            True(!corruptStore.PersistenceHealthy, "corrupt journal fails closed");
            True(File.Exists(Path.Combine(corruptRoot, "journal.json.corrupt")), "corrupt journal is preserved as evidence");
            Equal("{broken", await File.ReadAllTextAsync(Path.Combine(corruptRoot, "journal.json")),
                "corrupt journal is never overwritten");
            Directory.Delete(corruptRoot, recursive: true);

            var badRoot = Path.Combine(Path.GetTempPath(), $"aidictation-windows-storage-{Guid.NewGuid():N}");
            await File.WriteAllTextAsync(badRoot, "not a directory");
            await ThrowsAsync<Exception>(() => new AudioProcessingStore(badRoot).BeginCaptureAsync(cloud));
            File.Delete(badRoot);
        }
        finally
        {
            try { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); } catch { }
        }
    }

    private static async Task VerifyFinalizedAdoptionRecoveryAsync()
    {
        var root = Path.Combine(
            Path.GetTempPath(),
            $"aidictation-windows-adoption-{Guid.NewGuid():N}");
        var moveFailureRoot = Path.Combine(
            Path.GetTempPath(),
            $"aidictation-windows-adoption-move-{Guid.NewGuid():N}");
        try
        {
            var store = new AudioProcessingStore(root);
            var snapshot = Snapshot("local", "shutdown adoption");

            var preparing = await store.BeginCaptureAsync(snapshot);
            WriteWave(preparing.Entry!.PartialSourcePath, 2_048);
            var preparingProof = new RecorderFinalizationResult(
                true,
                preparing.Entry.PartialSourcePath,
                null);
            var adoptedPreparing = await store.AdoptFinalizedCaptureAsync(
                preparing.Lease!,
                preparingProof);
            True(adoptedPreparing.Applied,
                "shutdown adoption accepts a fully validated owned Preparing capture");
            Equal(AudioProcessingStage.ReadyForRecognition, adoptedPreparing.Entry!.Stage,
                "Preparing adoption reaches the retryable recognition boundary");
            Equal(AudioSourceIntegrity.Complete, adoptedPreparing.Entry.SourceIntegrity,
                "Preparing adoption records complete source integrity");
            True(File.Exists(adoptedPreparing.Entry.FinalSourcePath) &&
                 !File.Exists(adoptedPreparing.Entry.PartialSourcePath),
                "Preparing adoption atomically promotes the closed WAVE");
            var preparingTerminal = await store.AbandonAttemptAsync(
                adoptedPreparing.Lease!,
                true,
                "app closed",
                AudioSourceIntegrity.Complete);
            Equal(AudioSourceIntegrity.Complete, preparingTerminal.Entry!.SourceIntegrity,
                "shutdown terminalization keeps an adopted source retryable");
            var lateNegative = await store.RecordCaptureKnownIncompleteAsync(
                preparingTerminal.Lease!,
                "late native stop exception");
            True(lateNegative.Applied &&
                 lateNegative.Entry?.SourceIntegrity == AudioSourceIntegrity.KnownIncomplete &&
                 lateNegative.Entry.FinalizationProven == false,
                "an exact late negative proof downgrades an already-terminal adopted source");

            var contradictory = await store.BeginCaptureAsync(snapshot);
            WriteWave(contradictory.Entry!.PartialSourcePath, 2_048);
            var contradictoryProof = await store.AdoptFinalizedCaptureAsync(
                contradictory.Lease!,
                new RecorderFinalizationResult(
                    true,
                    contradictory.Entry.PartialSourcePath,
                    null,
                    TimedOut: true,
                    KnownIncomplete: true));
            True(!contradictoryProof.Applied &&
                 contradictoryProof.Entry?.FinalizationProven == false,
                "a contradictory timeout/negative record can never authorize promotion");
            _ = await store.AbandonAttemptAsync(
                contradictory.Lease!,
                false,
                "contradictory proof rejected",
                AudioSourceIntegrity.KnownIncomplete);

            var stale = await store.BeginCaptureAsync(snapshot);
            WriteWave(stale.Entry!.PartialSourcePath, 2_048);
            var ready = await store.CaptureBecameReadyAsync(stale.Lease!);
            True(ready.Applied && ready.Lease!.Revision > stale.Lease!.Revision,
                "ready commit advances the lease before the stale-caller regression");
            var staleProof = new RecorderFinalizationResult(
                true,
                stale.Entry.PartialSourcePath,
                null);
            var adoptedStale = await store.AdoptFinalizedCaptureAsync(
                stale.Lease!,
                staleProof);
            True(adoptedStale.Applied,
                "shutdown adoption accepts a stale revision only for the same owned attempt");
            Equal(AudioSourceIntegrity.Complete, adoptedStale.Entry!.SourceIntegrity,
                "stale Recording lease adoption still requires a fully valid WAVE");
            var newerAttempt = await store.BeginRecognitionAsync(
                stale.Entry.RecordingId,
                snapshot);
            True(newerAttempt.Applied && newerAttempt.Lease != null,
                "stale-negative fence fixture starts a newer recognition attempt");
            var staleNegative = await store.RecordCaptureKnownIncompleteAsync(
                stale.Lease!,
                "old capture callback");
            True(!staleNegative.Applied &&
                 staleNegative.Entry?.SourceIntegrity == AudioSourceIntegrity.Complete,
                "a new AttemptId fences an old capture's late negative callback");
            _ = await store.FailAsync(
                newerAttempt.Lease!,
                "finish stale-negative fence fixture",
                AudioSourceIntegrity.Complete);
            var deleted = await store.TombstoneAsync(stale.Entry.RecordingId);
            True(deleted.Applied,
                "delete fence fixture commits its tombstone");
            var deletedNegative = await store.RecordCaptureKnownIncompleteAsync(
                stale.Lease!,
                "callback after Delete");
            True(!deletedNegative.Applied &&
                 deletedNegative.Entry?.Stage == AudioProcessingStage.Deleted,
                "Delete durably fences an old capture's late negative callback");

            var beforeClear = await store.BeginCaptureAsync(snapshot);
            WriteWave(beforeClear.Entry!.PartialSourcePath, 2_048);
            var beforeClearAdopted = await store.AdoptFinalizedCaptureAsync(
                beforeClear.Lease!,
                new RecorderFinalizationResult(
                    true,
                    beforeClear.Entry.PartialSourcePath,
                    null));
            _ = await store.AbandonAttemptAsync(
                beforeClearAdopted.Lease!,
                true,
                "terminal before Clear",
                AudioSourceIntegrity.Complete);
            var cleared = await store.ClearAsync();
            True(cleared.Applied,
                "Clear fence fixture commits its generation");
            var clearedNegative = await store.RecordCaptureKnownIncompleteAsync(
                beforeClear.Lease!,
                "callback after Clear");
            True(!clearedNegative.Applied &&
                 clearedNegative.Entry?.Stage == AudioProcessingStage.Deleted,
                "Clear generation durably fences an old capture's late negative callback");

            var moveFailingStore = new AudioProcessingStore(
                moveFailureRoot,
                moveManagedSource: (_, _) => throw new IOException("injected move lock"));
            var moveCapture = await moveFailingStore.BeginCaptureAsync(snapshot);
            WriteWave(moveCapture.Entry!.PartialSourcePath, 2_048);
            await ThrowsAsync<AudioStoreException>(() =>
                moveFailingStore.AdoptFinalizedCaptureAsync(
                    moveCapture.Lease!,
                    new RecorderFinalizationResult(
                        true,
                        moveCapture.Entry.PartialSourcePath,
                        null)));
            var marked = await moveFailingStore.GetAsync(moveCapture.Entry.RecordingId);
            True(marked?.FinalizationProven == true &&
                 marked.Stage == AudioProcessingStage.Finalizing,
                "adoption persists finalization proof before a fallible source move");
            True(File.Exists(moveCapture.Entry.PartialSourcePath),
                "failed adoption move preserves the complete partial source");

            var moveRecovered = (await new AudioProcessingStore(moveFailureRoot)
                    .RecoverOnLaunchAsync())
                .Single(entry => entry.RecordingId == moveCapture.Entry.RecordingId);
            Equal(AudioProcessingStage.Failed, moveRecovered.Stage,
                "launch terminalizes a move-interrupted adoption");
            Equal(AudioSourceIntegrity.Complete, moveRecovered.SourceIntegrity,
                "launch promotes a move-interrupted valid WAVE as retryable");
            True(File.Exists(moveRecovered.FinalSourcePath),
                "launch completes the previously interrupted same-volume promotion");
        }
        finally
        {
            try { if (Directory.Exists(root)) Directory.Delete(root, recursive: true); } catch { }
            try
            {
                if (Directory.Exists(moveFailureRoot))
                    Directory.Delete(moveFailureRoot, recursive: true);
            }
            catch { }
        }
    }

    private static async Task VerifyDeferredDeletedCleanupAsync()
    {
        static async Task<AudioProcessingEntry> CreateTerminalWithCompleteSourceAsync(
            AudioProcessingStore store,
            string context)
        {
            var capture = await store.BeginCaptureAsync(Snapshot("local", context));
            WriteWave(capture.Entry!.PartialSourcePath, 2_048);
            var ready = await store.CaptureBecameReadyAsync(capture.Lease!);
            var finalizing = await store.BeginFinalizationAsync(ready.Lease!);
            var accepted = await store.AdoptFinalizedCaptureAsync(
                finalizing.Lease!,
                new RecorderFinalizationResult(
                    true,
                    finalizing.Entry!.PartialSourcePath,
                    null));
            var failed = await store.FailAsync(
                accepted.Lease!,
                "terminal fixture",
                AudioSourceIntegrity.Complete);
            return failed.Entry!;
        }

        var deleteRoot = Path.Combine(
            Path.GetTempPath(),
            $"aidictation-windows-delete-debt-{Guid.NewGuid():N}");
        var clearRoot = Path.Combine(
            Path.GetTempPath(),
            $"aidictation-windows-clear-debt-{Guid.NewGuid():N}");
        var hangingDeleteRoot = Path.Combine(
            Path.GetTempPath(),
            $"aidictation-windows-delete-hang-{Guid.NewGuid():N}");
        var hangingClearRoot = Path.Combine(
            Path.GetTempPath(),
            $"aidictation-windows-clear-hang-{Guid.NewGuid():N}");
        try
        {
            var deleteStore = new AudioProcessingStore(
                deleteRoot,
                deleteManagedSource: _ => throw new IOException("injected locked source"));
            var deleteEntry = await CreateTerminalWithCompleteSourceAsync(
                deleteStore,
                "delete cleanup debt");
            var deleted = await deleteStore.TombstoneAsync(deleteEntry.RecordingId);
            True(deleted.Applied,
                "Delete remains successful after its durable tombstone when file cleanup is locked");
            Equal(AudioProcessingStage.Deleted,
                (await deleteStore.GetAsync(deleteEntry.RecordingId))!.Stage,
                "locked physical cleanup cannot resurrect a durable Delete");
            True(File.Exists(deleteEntry.FinalSourcePath),
                "locked Delete source remains as retryable cleanup debt");

            var stillLocked = new AudioProcessingStore(
                deleteRoot,
                deleteManagedSource: _ => throw new IOException("still locked"));
            var firstRecovery = await stillLocked.RecoverOnLaunchAsync();
            Equal(AudioProcessingStage.Deleted,
                firstRecovery.Single(entry => entry.RecordingId == deleteEntry.RecordingId).Stage,
                "launch returns Deleted rows even while physical cleanup remains locked");
            True(File.Exists(deleteEntry.FinalSourcePath),
                "failed launch cleanup preserves the source for another safe retry");

            var deleteRecovered = await new AudioProcessingStore(deleteRoot)
                .RecoverOnLaunchAsync();
            Equal(AudioProcessingStage.Deleted,
                deleteRecovered.Single(entry => entry.RecordingId == deleteEntry.RecordingId).Stage,
                "a later launch keeps the durable tombstone authoritative");
            await WaitUntilAsync(
                () => !File.Exists(deleteEntry.FinalSourcePath),
                TimeSpan.FromSeconds(1));
            True(!File.Exists(deleteEntry.FinalSourcePath),
                "a later launch retries and completes deferred Delete cleanup");

            var clearStore = new AudioProcessingStore(
                clearRoot,
                deleteManagedSource: _ => throw new IOException("injected clear lock"));
            var clearEntry = await CreateTerminalWithCompleteSourceAsync(
                clearStore,
                "clear cleanup debt");
            var cleared = await clearStore.ClearAsync();
            True(cleared.Applied,
                "Clear remains successful after durable deletion when physical cleanup is locked");
            Equal(AudioProcessingStage.Deleted,
                (await clearStore.GetAsync(clearEntry.RecordingId))!.Stage,
                "locked Clear cleanup cannot restore a cleared row");
            True(File.Exists(clearEntry.FinalSourcePath),
                "locked Clear source remains as cleanup debt");

            var clearRecovered = await new AudioProcessingStore(clearRoot)
                .RecoverOnLaunchAsync();
            Equal(AudioProcessingStage.Deleted,
                clearRecovered.Single(entry => entry.RecordingId == clearEntry.RecordingId).Stage,
                "launch preserves Clear's durable Deleted state");
            await WaitUntilAsync(
                () => !File.Exists(clearEntry.FinalSourcePath),
                TimeSpan.FromSeconds(1));
            True(!File.Exists(clearEntry.FinalSourcePath),
                "launch retries and completes deferred Clear cleanup");

            using var deleteEntered = new ManualResetEventSlim();
            using var deleteRelease = new ManualResetEventSlim();
            var hangingDeleteStore = new AudioProcessingStore(
                hangingDeleteRoot,
                deleteManagedSource: path =>
                {
                    deleteEntered.Set();
                    deleteRelease.Wait();
                    File.Delete(path);
                });
            var hangingDeleteEntry = await CreateTerminalWithCompleteSourceAsync(
                hangingDeleteStore,
                "blocking Delete cleanup");
            var hangingDelete = await hangingDeleteStore
                .TombstoneAsync(hangingDeleteEntry.RecordingId)
                .WaitAsync(TimeSpan.FromMilliseconds(250));
            True(hangingDelete.Applied,
                "Delete returns its durable result without waiting for a stuck physical delete");
            True(deleteEntered.Wait(TimeSpan.FromSeconds(1)),
                "detached Delete cleanup reaches the injected blocked file operation");
            Equal(AudioProcessingStage.Deleted,
                (await hangingDeleteStore.GetAsync(hangingDeleteEntry.RecordingId))!.Stage,
                "a stuck cleanup cannot delay or undo the durable Delete state");
            deleteRelease.Set();
            await WaitUntilAsync(
                () => !File.Exists(hangingDeleteEntry.FinalSourcePath),
                TimeSpan.FromSeconds(1));

            using var clearEntered = new ManualResetEventSlim();
            using var clearRelease = new ManualResetEventSlim();
            var hangingClearStore = new AudioProcessingStore(
                hangingClearRoot,
                deleteManagedSource: path =>
                {
                    clearEntered.Set();
                    clearRelease.Wait();
                    File.Delete(path);
                });
            var hangingClearEntry = await CreateTerminalWithCompleteSourceAsync(
                hangingClearStore,
                "blocking Clear cleanup");
            var hangingClear = await hangingClearStore
                .ClearAsync()
                .WaitAsync(TimeSpan.FromMilliseconds(250));
            True(hangingClear.Applied &&
                 hangingClear.AffectedRecordingIds?.SequenceEqual(
                     new[] { hangingClearEntry.RecordingId }) == true,
                "Clear returns exact committed IDs without waiting for stuck file cleanup");
            True(clearEntered.Wait(TimeSpan.FromSeconds(1)),
                "detached Clear cleanup reaches the injected blocked file operation");
            Equal(AudioProcessingStage.Deleted,
                (await hangingClearStore.GetAsync(hangingClearEntry.RecordingId))!.Stage,
                "a stuck cleanup cannot delay or undo Clear's durable state");
            clearRelease.Set();
            await WaitUntilAsync(
                () => !File.Exists(hangingClearEntry.FinalSourcePath),
                TimeSpan.FromSeconds(1));
        }
        finally
        {
            try { if (Directory.Exists(deleteRoot)) Directory.Delete(deleteRoot, recursive: true); } catch { }
            try { if (Directory.Exists(clearRoot)) Directory.Delete(clearRoot, recursive: true); } catch { }
            try { if (Directory.Exists(hangingDeleteRoot)) Directory.Delete(hangingDeleteRoot, recursive: true); } catch { }
            try { if (Directory.Exists(hangingClearRoot)) Directory.Delete(hangingClearRoot, recursive: true); } catch { }
        }
    }

    private static async Task VerifyCleanupFallbacksAsync()
    {
        var snapshot = TranscriptionAttemptSnapshotFactory.Capture(
            "local",
            new[] { "en" },
            new[] { "English" },
            new[] { "WhisperMate" },
            new[] { new TextReplacementSnapshot("whisper mate", "WhisperMate") },
            new[] { new TextReplacementSnapshot("ship it", "ship the verified build") },
            "Use sentence case.",
            cleanupEnabled: true);

        string? sentBody = null;
        using (var client = new HttpClient(new DelegateHandler(async (request, token) =>
               {
                   sentBody = await request.Content!.ReadAsStringAsync(token);
                   return JsonResponse(HttpStatusCode.OK, "cleaned complete transcript", "stop");
               })))
        {
            var service = CleanupService(client, TimeSpan.FromSeconds(1));
            Equal("cleaned complete transcript",
                await service.PostProcessAsync(
                    "raw complete transcript",
                    new[] { "English", "Polish" },
                    snapshot),
                "cleanup accepts a non-empty exact-200 completion with finish_reason stop");
        }
        True(sentBody?.Contains("SOURCE_TRANSCRIPT_JSON", StringComparison.Ordinal) == true,
            "offline cleanup request delimits the authoritative source");
        True(sentBody?.Contains("REFERENCE_CONTEXT_JSON_LINES", StringComparison.Ordinal) == true,
            "offline cleanup request delimits personal reference context");
        True(sentBody?.Contains("WhisperMate", StringComparison.Ordinal) == true &&
             sentBody.Contains("ship the verified build", StringComparison.Ordinal) &&
             sentBody.Contains("Use sentence case.", StringComparison.Ordinal),
            "offline cleanup receives vocabulary, replacements, expansions, and rules");
        True(sentBody?.Contains("English", StringComparison.Ordinal) == true &&
             sentBody.Contains("Polish", StringComparison.Ordinal),
            "offline cleanup preserves every selected language name");

        foreach (var status in new[] { HttpStatusCode.Accepted, HttpStatusCode.PartialContent })
        {
            using var client = new HttpClient(new DelegateHandler((_, _) =>
                Task.FromResult(JsonResponse(status, "must not win", "stop"))));
            Equal("raw transcript",
                await CleanupService(client, TimeSpan.FromSeconds(1))
                    .PostProcessAsync("raw transcript", new[] { "English" }, snapshot),
                $"cleanup falls back to raw text for HTTP {(int)status}");
        }

        using (var client = new HttpClient(new DelegateHandler((_, _) =>
               Task.FromResult(new HttpResponseMessage(HttpStatusCode.InternalServerError)
               {
                   Content = new BlockingContent()
               }))))
        {
            var started = DateTime.UtcNow;
            Equal("raw transcript",
                await CleanupService(client, TimeSpan.FromMinutes(1))
                    .PostProcessAsync("raw transcript", new[] { "English" }, snapshot),
                "cleanup 500 keeps the complete raw transcript");
            True(DateTime.UtcNow - started < TimeSpan.FromMilliseconds(500),
                "cleanup classifies non-200 headers without draining a stalled body");
        }

        using (var client = new HttpClient(new DelegateHandler((_, _) =>
               {
                   var content = new ByteArrayContent(
                       new byte[BoundedHttpContentReader.MaxResponseBytes + 1]);
                   content.Headers.ContentLength =
                       BoundedHttpContentReader.MaxResponseBytes + 1;
                   return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
                   {
                       Content = content
                   });
               })))
        {
            Equal("raw transcript",
                await CleanupService(client, TimeSpan.FromSeconds(1))
                    .PostProcessAsync("raw transcript", new[] { "English" }, snapshot),
                "oversized cleanup completion keeps the complete raw transcript");
        }

        foreach (var response in new[]
                 {
                     JsonResponse(HttpStatusCode.OK, "", "stop"),
                     JsonResponse(HttpStatusCode.OK, "truncated", "length"),
                     new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("{broken") }
                 })
        {
            using (response)
            using (var client = new HttpClient(new DelegateHandler((_, _) => Task.FromResult(response))))
            {
                Equal("raw transcript",
                    await CleanupService(client, TimeSpan.FromSeconds(1))
                        .PostProcessAsync("raw transcript", new[] { "English" }, snapshot),
                    "empty, truncated, or malformed cleanup output keeps complete raw text");
            }
        }

        using (var client = new HttpClient(new DelegateHandler(async (_, token) =>
               {
                   await Task.Delay(Timeout.InfiniteTimeSpan, token);
                   return JsonResponse(HttpStatusCode.OK, "late", "stop");
               })))
        {
            Equal("raw transcript",
                await CleanupService(client, TimeSpan.FromMilliseconds(25))
                    .PostProcessAsync("raw transcript", new[] { "English" }, snapshot),
                "cleanup timeout keeps complete raw text");
        }

        var ignoredCleanup = new TaskCompletionSource<HttpResponseMessage>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        using (var client = new HttpClient(new DelegateHandler((_, _) => ignoredCleanup.Task)))
        {
            var started = DateTime.UtcNow;
            Equal("raw transcript",
                await CleanupService(client, TimeSpan.FromMilliseconds(25))
                    .PostProcessAsync("raw transcript", new[] { "English" }, snapshot),
                "cleanup transport that ignores cancellation still falls back to raw text");
            True(DateTime.UtcNow - started < TimeSpan.FromMilliseconds(500),
                "cleanup hard deadline does not wait for cooperative transport cancellation");
        }
        ignoredCleanup.TrySetResult(JsonResponse(HttpStatusCode.OK, "late cleanup", "stop"));
    }

    private static async Task VerifyCapturedContextAndGenerationResetAsync()
    {
        var languages = new List<string> { "en" };
        var languageNames = new List<string> { "English" };
        var vocabulary = new List<string> { "WhisperMate" };
        var replacements = new List<TextReplacementSnapshot>
        {
            new("whisper mate", "WhisperMate")
        };
        var expansions = new List<TextReplacementSnapshot>
        {
            new("ship it", "ship the verified build")
        };
        var snapshot = TranscriptionAttemptSnapshotFactory.Capture(
            "cloud",
            languages,
            languageNames,
            vocabulary,
            replacements,
            expansions,
            "Use sentence case.",
            cleanupEnabled: true);

        languages[0] = "de";
        languageNames[0] = "German";
        vocabulary[0] = "MUTATED";
        replacements[0] = new TextReplacementSnapshot("changed", "CHANGED");
        expansions[0] = new TextReplacementSnapshot("changed", "CHANGED");

        Equal("en", snapshot.LanguageCodes.Single(), "attempt freezes languages before the first await");
        Equal("WhisperMate", snapshot.Vocabulary!.Single(), "attempt freezes vocabulary before the first await");
        Equal("whisper mate", snapshot.Replacements.Single().Trigger,
            "attempt freezes explicit replacements before the first await");
        Equal("ship it", snapshot.Expansions.Single().Trigger,
            "attempt freezes phrase expansions before the first await");
        True(snapshot.RecognitionPrompt?.Contains("WhisperMate", StringComparison.Ordinal) == true &&
             snapshot.RecognitionPrompt.Contains("whisper mate", StringComparison.Ordinal) &&
             snapshot.RecognitionPrompt.Contains("ship it", StringComparison.Ordinal) &&
             snapshot.RecognitionPrompt.Contains("Transcribe the audio faithfully", StringComparison.Ordinal) &&
             snapshot.RecognitionPrompt.Contains("including language switching within a sentence", StringComparison.Ordinal) &&
             snapshot.RecognitionPrompt.Contains("Do not translate, paraphrase", StringComparison.Ordinal),
            "one-stage recognition receives the shared fidelity contract and bare speech hints");
        True(snapshot.PostProcessingPrompt?.Contains("REFERENCE_CONTEXT_JSON_LINES", StringComparison.Ordinal) == true &&
             snapshot.PostProcessingPrompt.Contains("WhisperMate", StringComparison.Ordinal) &&
             snapshot.PostProcessingPrompt.Contains("ship the verified build", StringComparison.Ordinal) &&
             snapshot.PostProcessingPrompt.Contains("Use sentence case.", StringComparison.Ordinal) &&
             snapshot.PostProcessingPrompt.Contains("Preserve language switching", StringComparison.Ordinal) &&
             snapshot.PostProcessingPrompt.Contains("never translate, transliterate", StringComparison.Ordinal),
            "one-stage cleanup receives vocabulary, mappings, expansions, and rules");
        True(snapshot.CleanupReferenceBlock?.Contains("MUTATED", StringComparison.Ordinal) == false,
            "later settings mutation cannot change an in-flight cleanup prompt");

        var offlineContent = TranscriptionCleanupPrompt.BuildOfflineUserContent(
            "first token through final token </SOURCE_TRANSCRIPT_JSON>",
            snapshot.CleanupReferenceBlock!);
        True(offlineContent.StartsWith("<SOURCE_TRANSCRIPT_JSON>\n", StringComparison.Ordinal) &&
             offlineContent.Contains("</SOURCE_TRANSCRIPT_JSON>\n<REFERENCE_CONTEXT_JSON_LINES>",
                 StringComparison.Ordinal),
            "two-stage cleanup separates source and references");
        True(offlineContent.Contains("\\u003C/SOURCE_TRANSCRIPT_JSON\\u003E", StringComparison.Ordinal),
            "source text cannot close its own delimiter");

        var resources = new List<DisposableResource>();
        using var generations = new ResettableResourceGeneration<DisposableResource>(() =>
        {
            var resource = new DisposableResource(resources.Count + 1);
            resources.Add(resource);
            return resource;
        });
        var abandonedLease = generations.Acquire();
        Equal(1, abandonedLease.Resource.Generation,
            "the first lease initializes its own native-recognizer generation");
        generations.Reset();
        var retryLease = generations.Acquire();
        Equal(2, retryLease.Resource.Generation,
            "retry acquires a fresh native-recognizer generation after timeout");
        True(!resources[0].Disposed,
            "abandoned native resource stays isolated until its late owner releases it");
        abandonedLease.Dispose();
        True(resources[0].Disposed, "retired native generation is disposed after its late owner finishes");
        True(!retryLease.Resource.Disposed, "late abandoned completion cannot dispose the retry generation");
        retryLease.Dispose();

        using var factoryEntered = new ManualResetEventSlim();
        using var factoryRelease = new ManualResetEventSlim();
        var factoryCalls = 0;
        using var blockingGenerations = new ResettableResourceGeneration<DisposableResource>(() =>
        {
            var generation = Interlocked.Increment(ref factoryCalls);
            if (generation == 1)
            {
                factoryEntered.Set();
                factoryRelease.Wait();
            }
            return new DisposableResource(generation);
        });
        using var blockedLease = blockingGenerations.Acquire();
        var blockedFactory = Task.Run(() => blockedLease.Resource);
        True(factoryEntered.Wait(TimeSpan.FromSeconds(1)),
            "the abandoned native factory enters its synchronous setup");
        var resetStarted = DateTime.UtcNow;
        blockingGenerations.Reset();
        True(DateTime.UtcNow - resetStarted < TimeSpan.FromMilliseconds(250),
            "reset does not wait for an abandoned native factory");
        using var freshLease = blockingGenerations.Acquire();
        Equal(2, freshLease.Resource.Generation,
            "retry initializes a fresh generation while the abandoned factory is still blocked");
        factoryRelease.Set();
        Equal(1, (await blockedFactory.ConfigureAwait(false)).Generation,
            "the abandoned factory remains isolated in its retired generation");

        var captureFence = new AudioCaptureTerminalFence();
        True(captureFence.IsAcceptingFrames, "capture accepts frames before a terminal event");
        True(captureFence.TryClaimTerminal(),
            "write failure can immediately claim terminal ownership without native StopRecording");
        True(!captureFence.IsAcceptingFrames,
            "write failure fences every later audio buffer before detached native cleanup");
        True(!captureFence.TryClaimTerminal(),
            "late native RecordingStopped callback cannot finalize the abandoned session twice");
        True(!captureFence.StopWasRequested,
            "unexpected write failure remains distinguishable from an intentional stop");
    }

    private static async Task VerifyBlockedExporterAsync()
    {
        using var entered = new ManualResetEventSlim();
        using var release = new ManualResetEventSlim();
        var workspace = Path.Combine(
            Path.GetTempPath(),
            $"aidictation-detached-export-{Guid.NewGuid():N}");
        Directory.CreateDirectory(workspace);
        await File.WriteAllTextAsync(Path.Combine(workspace, "started.tmp"), "started");
        var started = DateTime.UtcNow;
        var export = AudioExportDeadline.RunAsync(
            _ =>
            {
                entered.Set();
                release.Wait();
                File.WriteAllText(Path.Combine(workspace, "late.tmp"), "late");
                return "late export";
            },
            TimeSpan.FromMilliseconds(25),
            CancellationToken.None,
            () =>
            {
                if (Directory.Exists(workspace)) Directory.Delete(workspace, recursive: true);
            });
        try
        {
            True(entered.Wait(TimeSpan.FromSeconds(1)), "blocked exporter starts on its detached worker");
            await ThrowsAsync<TimeoutException>(async () => _ = await export);
            True(DateTime.UtcNow - started < TimeSpan.FromMilliseconds(500),
                "blocked exporter returns at its deadline even when native work ignores cancellation");
        }
        finally
        {
            release.Set();
        }
        await WaitUntilAsync(() => !Directory.Exists(workspace), TimeSpan.FromSeconds(1));
        True(!Directory.Exists(workspace),
            "detached exporter owns eventual temporary-workspace cleanup after its late exit");
    }

    private static LanguagePostProcessService CleanupService(HttpClient client, TimeSpan deadline) =>
        new(client, new Uri("https://example.invalid/cleanup"), "contract-key", "contract-model", deadline);

    private static HttpResponseMessage JsonResponse(HttpStatusCode status, string content, string finishReason) =>
        new(status)
        {
            Content = new StringContent(System.Text.Json.JsonSerializer.Serialize(new
            {
                choices = new[]
                {
                    new { finish_reason = finishReason, message = new { content } }
                }
            }))
        };

    private static async Task VerifyCoordinatorDeadlineRacesAsync()
    {
        {
            var fixture = new CoordinatorFixture();
            fixture.State.StartPreparingPublished = () =>
                fixture.Coordinator
                    .CancelAsync("reentrant start cancellation")
                    .GetAwaiter()
                    .GetResult();

            var outcome = await fixture.Coordinator.StartCaptureAsync(false, null);
            True(!outcome.Started,
                "synchronous StartPreparing callback cancellation prevents capture ownership");
            Equal(0, fixture.Recorder.StartCalls,
                "reentrant cancellation cannot open a hidden microphone");
            Equal("Idle", fixture.State.Current,
                "reentrant cancellation leaves the UI idle");
            True(!fixture.Coordinator.HasActiveAttempt,
                "reentrant cancellation leaves no pending or active attempt");
        }

        {
            var fixture = new CoordinatorFixture();
            fixture.State.RejectRecordingBecameReady = true;
            var outcome = await fixture.Coordinator.StartCaptureAsync(false, null);
            True(!outcome.Started,
                "recording-ready publication refusal rejects startup");
            await fixture.Recorder.AbortObserved.Task.WaitAsync(TimeSpan.FromSeconds(1));
            True(!fixture.Coordinator.HasActiveAttempt,
                "recording-ready publication refusal releases its owner");
            Equal("Error", fixture.State.Current,
                "recording-ready publication refusal produces a recoverable error");
            await WaitUntilAsync(
                () => fixture.Store.LastStage is AudioProcessingStage.Cancelled or
                    AudioProcessingStage.Failed,
                TimeSpan.FromSeconds(1));
        }

        {
            var fixture = new CoordinatorFixture();
            fixture.State.RecordingReadyPublished = () =>
                fixture.Coordinator
                    .CancelAsync("reentrant ready cancellation")
                    .GetAwaiter()
                    .GetResult();
            var outcome = await fixture.Coordinator.StartCaptureAsync(false, null);
            True(!outcome.Started,
                "synchronous recording-ready cancellation cannot report Started");
            Equal("Idle", fixture.State.Current,
                "recording-ready reentrant cancellation remains idle");
            True(!fixture.Coordinator.HasActiveAttempt,
                "recording-ready reentrant cancellation clears ownership");
            await fixture.Recorder.AbortObserved.Task.WaitAsync(TimeSpan.FromSeconds(1));
        }

        {
            var fixture = new CoordinatorFixture();
            var retryPath = Path.Combine(
                Path.GetTempPath(),
                $"retry-shutdown-{Guid.NewGuid():N}.wav");
            await File.WriteAllBytesAsync(retryPath, new byte[] { 1 });
            try
            {
                var retryId = Guid.NewGuid();
                fixture.Store.SeedTerminal(retryId);
                await fixture.History.UpsertAsync(new AIDictation.Models.Recording
                {
                    Id = retryId,
                    AudioFilePath = retryPath,
                    Status = AIDictation.Models.TranscriptionStatus.Failed,
                    SourceIntegrity = AIDictation.Models.RecordingSourceIntegrity.Complete,
                    Revision = 1
                });
                fixture.State.BlockStartRetrying = true;
                var retryTask = Task.Run(
                    () => fixture.Coordinator.RetryAsync(retryId, "local"));
                True(fixture.State.StartRetryingEntered.Wait(TimeSpan.FromSeconds(1)),
                    "retry UI transition entered the deterministic shutdown gap");
                var shutdownTask = Task.Run(
                    () => fixture.Coordinator.ShutdownAsync(TimeSpan.FromSeconds(1)));
                await Task.Delay(20);
                True(!shutdownTask.IsCompleted,
                    "shutdown serializes with retry UI ownership publication");
                fixture.State.ReleaseStartRetrying();
                _ = await retryTask.WaitAsync(TimeSpan.FromSeconds(1));
                await shutdownTask.WaitAsync(TimeSpan.FromSeconds(1));
                Equal("Idle", fixture.State.Current,
                    "shutdown cannot leave a late retry Processing state");
                True(!fixture.Coordinator.HasActiveAttempt,
                    "retry-shutdown race leaves no foreground owner");
            }
            finally
            {
                try { File.Delete(retryPath); } catch { }
            }
        }

        {
            var fixture = new CoordinatorFixture();
            fixture.Pipeline.BlockCaptureSnapshot = true;
            var startTask = Task.Run(
                () => fixture.Coordinator.StartCaptureAsync(false, null));
            True(
                fixture.Pipeline.CaptureSnapshotEntered.Wait(TimeSpan.FromSeconds(1)),
                "capture snapshot entered before the deterministic shutdown registration gap");

            await fixture.Coordinator
                .ShutdownAsync(TimeSpan.FromMilliseconds(120))
                .WaitAsync(TimeSpan.FromSeconds(1));
            fixture.Pipeline.ReleaseCaptureSnapshot();
            var outcome = await startTask.WaitAsync(TimeSpan.FromSeconds(1));

            True(!outcome.Started,
                "a start that began before shutdown cannot register after shutdown completed");
            Equal(0, fixture.Recorder.StartCalls,
                "post-shutdown registration fence prevents a late microphone open");
            Equal("Idle", fixture.State.Current,
                "the rejected late start leaves shutdown UI state idle");
        }

        {
            var fixture = new CoordinatorFixture();
            fixture.Store.BlockBeginCapture = true;
            var startTask = fixture.Coordinator.StartCaptureAsync(false, null);
            await fixture.Store.BeginCaptureEntered.Task.WaitAsync(TimeSpan.FromSeconds(1));

            var started = DateTime.UtcNow;
            await fixture.Coordinator.CancelAsync("cancel during startup");
            var cancelElapsed = DateTime.UtcNow - started;
            True(cancelElapsed < TimeSpan.FromMilliseconds(250),
                "Cancel returns immediately while pre-first-buffer capture setup is blocked");
            Equal("Idle", fixture.State.Current, "startup cancellation immediately returns UI to idle");
            var outcome = await startTask.WaitAsync(TimeSpan.FromSeconds(1));
            True(!outcome.Started, "cancelled startup cannot become a live capture");
            fixture.Store.ReleaseBeginCapture();
            await WaitUntilAsync(
                () => fixture.Store.LastStage == AudioProcessingStage.Deleted,
                TimeSpan.FromSeconds(1));
            Equal(0, fixture.Recorder.StartCalls,
                "late durable startup completion cannot open the microphone after cancellation");
            Equal(AudioProcessingStage.Deleted, fixture.Store.LastStage,
                "late startup journal row is terminalized and tombstoned in-session");
            True(!fixture.Coordinator.HasActiveAttempt,
                "cancelled pending startup leaves no foreground attempt owner");
        }

        {
            var fixture = new CoordinatorFixture();
            fixture.Store.BlockCaptureBecameReady = true;
            var startTask = fixture.Coordinator.StartCaptureAsync(false, null);
            await fixture.Store.CaptureBecameReadyEntered.Task
                .WaitAsync(TimeSpan.FromSeconds(1));
            var recordingId = fixture.Store.RecordingId;

            await fixture.Coordinator
                .ShutdownAsync(TimeSpan.FromSeconds(1))
                .WaitAsync(TimeSpan.FromSeconds(1));
            var recovered = fixture.History.Get(recordingId);
            True(recovered != null,
                "shutdown projects a capture closed before its ready commit into History");
            Equal(AIDictation.Models.RecordingSourceIntegrity.Complete,
                recovered!.SourceIntegrity,
                "shutdown adopts a valid Preparing source as complete");
            Equal(AIDictation.Models.TranscriptionStatus.Cancelled,
                recovered.Status,
                "shutdown terminalizes the adopted capture for retry");
            True(fixture.Store.FinalizationProven,
                "shutdown persists positive proof before promoting a closed source");
            fixture.Store.ReleaseCaptureBecameReady();
            True(!(await startTask.WaitAsync(TimeSpan.FromSeconds(1))).Started,
                "late ready commit cannot revive the shutdown-owned capture");
            Equal("Idle", fixture.State.Current,
                "shutdown-ready race leaves the UI idle");
        }

        {
            var fixture = new CoordinatorFixture();
            True((await fixture.Coordinator.StartCaptureAsync(false, null)).Started,
                "active-cancel fixture starts after its first durable buffer");
            var recordingId = fixture.Store.RecordingId;
            var captureLease = fixture.Store.CurrentLease!;
            await fixture.Coordinator.CancelAsync("user cancelled active capture");
            Equal("Idle", fixture.State.Current,
                "active capture Cancel releases the UI immediately");
            True(!fixture.Coordinator.HasActiveAttempt,
                "active capture Cancel releases foreground ownership immediately");
            await fixture.Recorder.AbortObserved.Task.WaitAsync(TimeSpan.FromSeconds(1));
            await WaitUntilAsync(
                () => fixture.History.Get(recordingId)?.SourceIntegrity ==
                    AIDictation.Models.RecordingSourceIntegrity.Complete,
                TimeSpan.FromSeconds(1));
            Equal(AIDictation.Models.TranscriptionStatus.Cancelled,
                fixture.History.Get(recordingId)!.Status,
                "a fully closed cancelled capture remains retryable in History");
            True(fixture.Store.FinalizationProven,
                "active capture Cancel promotes only after recorder-confirmed proof");
            fixture.Recorder.RaiseUnexpected(
                captureLease,
                "late native stop exception");
            await WaitUntilAsync(
                () => fixture.History.Get(recordingId)?.SourceIntegrity ==
                    AIDictation.Models.RecordingSourceIntegrity.KnownIncomplete,
                TimeSpan.FromSeconds(1));
            Equal(AudioSourceIntegrity.KnownIncomplete,
                (await fixture.Store.GetAsync(recordingId))!.SourceIntegrity,
                "a delayed native stop exception monotonically downgrades the exact terminal capture");
            True(!fixture.Store.FinalizationProven,
                "late negative proof removes all launch-promotion authority");
        }

        {
            var fixture = new CoordinatorFixture();
            fixture.Recorder.BlockAbortProof = true;
            fixture.Recorder.ShutdownWaitsForAbortProof = true;
            True((await fixture.Coordinator.StartCaptureAsync(false, null)).Started,
                "late-close fixture starts capture");
            var recordingId = fixture.Store.RecordingId;
            await fixture.Coordinator.CancelAsync("cancel before writer close");
            await fixture.Recorder.AbortObserved.Task.WaitAsync(TimeSpan.FromSeconds(1));
            await WaitUntilAsync(
                () => fixture.Store.LastStage == AudioProcessingStage.Cancelled,
                TimeSpan.FromSeconds(1));
            Equal("Idle", fixture.State.Current,
                "late writer close never retains foreground UI");
            var shutdownTask = fixture.Coordinator
                .ShutdownAsync(TimeSpan.FromSeconds(1));
            await WaitUntilAsync(
                () => fixture.Store.LastStage == AudioProcessingStage.Cancelled,
                TimeSpan.FromSeconds(1));
            True(!fixture.Store.FinalizationProven,
                "proof timeout preserves audio without authorizing promotion");
            Equal(AIDictation.Models.RecordingSourceIntegrity.Unfinalized,
                fixture.History.Get(recordingId)!.SourceIntegrity,
                "proof timeout never claims completeness prematurely");

            await Task.Delay(20);
            True(!shutdownTask.IsCompleted,
                "immediate shutdown waits a retired writer close, not native Dispose");
            fixture.Recorder.ReleaseAbortProof();
            await shutdownTask.WaitAsync(TimeSpan.FromSeconds(1));
            await WaitUntilAsync(
                () => fixture.History.Get(recordingId)?.SourceIntegrity ==
                    AIDictation.Models.RecordingSourceIntegrity.Complete,
                TimeSpan.FromSeconds(1));
            Equal(AudioSourceIntegrity.Complete,
                (await fixture.Store.GetAsync(recordingId))!.SourceIntegrity,
                "late valid writer proof reconciles after bounded Cancel");
            True(fixture.Store.FinalizationProven,
                "late positive proof durably authorizes source promotion");
            Equal("Idle", fixture.State.Current,
                "Cancel followed by immediate shutdown finishes idle");
        }

        {
            var fixture = new CoordinatorFixture();
            fixture.Recorder.BlockAbortProof = true;
            True((await fixture.Coordinator.StartCaptureAsync(false, null)).Started,
                "known-incomplete fixture starts capture");
            var recordingId = fixture.Store.RecordingId;
            fixture.Recorder.RaiseUnexpected(
                fixture.Store.CurrentLease!,
                "injected capture write failure");
            await fixture.Recorder.AbortObserved.Task.WaitAsync(TimeSpan.FromSeconds(1));
            await WaitUntilAsync(
                () => fixture.Store.LastStage == AudioProcessingStage.Failed,
                TimeSpan.FromSeconds(1));
            True(!fixture.Store.FinalizationProven,
                "known-incomplete crash window remains non-promotable");
            Equal(AIDictation.Models.RecordingSourceIntegrity.KnownIncomplete,
                fixture.History.Get(recordingId)!.SourceIntegrity,
                "known-incomplete capture remains nonretryable");
            fixture.Recorder.ReleaseAbortProof();
        }

        {
            var fixture = new CoordinatorFixture();
            True((await fixture.Coordinator.StartCaptureAsync(false, null)).Started,
                "finalization race fixture starts capture");
            fixture.Store.BlockBeginFinalization = true;
            var stopTask = fixture.Coordinator.StopAndTranscribeAsync(TimeSpan.FromSeconds(5));
            await fixture.Store.BeginFinalizationEntered.Task.WaitAsync(TimeSpan.FromSeconds(1));

            var started = DateTime.UtcNow;
            await fixture.Coordinator.CancelAsync("cancel blocked finalization");
            True(DateTime.UtcNow - started < TimeSpan.FromMilliseconds(250),
                "Cancel does not wait for a blocked finalization journal write");
            Equal("Idle", fixture.State.Current,
                "blocked finalization cancellation immediately returns UI to idle");
            True(!(await stopTask.WaitAsync(TimeSpan.FromSeconds(1))).IsSuccess,
                "blocked finalization cannot deliver a transcript after cancellation");
            True(!fixture.Coordinator.HasActiveAttempt,
                "blocked finalization cancellation releases the foreground owner");
            fixture.Store.ReleaseBeginFinalization();
            await fixture.Recorder.AbortObserved.Task.WaitAsync(TimeSpan.FromSeconds(1));
        }

        {
            var fixture = new CoordinatorFixture();
            fixture.Pipeline.BlockOnCheckpoint = true;
            fixture.Store.BlockCheckpoint = true;
            True((await fixture.Coordinator.StartCaptureAsync(false, null)).Started,
                "checkpoint race fixture starts capture");
            var stopTask = fixture.Coordinator.StopAndTranscribeAsync(TimeSpan.FromSeconds(5));
            await fixture.Store.CheckpointEntered.Task.WaitAsync(TimeSpan.FromSeconds(1));
            var result = await stopTask.WaitAsync(TimeSpan.FromSeconds(1));
            True(!result.IsSuccess, "blocked checkpoint ends at the shared deadline");
            Equal("Error", fixture.State.Current,
                "blocked checkpoint releases the UI with a retryable error");
            True(!fixture.Coordinator.HasActiveAttempt,
                "blocked checkpoint releases its foreground attempt before persistence unblocks");
            await fixture.Pipeline.AbandonObserved.Task.WaitAsync(TimeSpan.FromSeconds(1));
            True(fixture.Pipeline.AbandonCalls > 0,
                "timed-out local recognition resets the native generation before retry");
            fixture.Store.ReleaseCheckpoint();
        }

        {
            var fixture = new CoordinatorFixture();
            fixture.Pipeline.BlockAfterRaw = true;
            True((await fixture.Coordinator.StartCaptureAsync(false, null)).Started,
                "raw-fallback fixture starts capture");
            var stopTask = fixture.Coordinator.StopAndTranscribeAsync(TimeSpan.FromSeconds(5));
            await fixture.Pipeline.AfterRawEntered.Task.WaitAsync(TimeSpan.FromSeconds(1));
            var result = await stopTask.WaitAsync(TimeSpan.FromSeconds(1));
            True(result.IsSuccess && result.Text == "complete raw transcript",
                "cleanup/global timeout commits the already-durable complete raw transcript");
            Equal("Result", fixture.State.Current,
                "optional cleanup timeout ends in Result rather than Failed");
            fixture.Pipeline.ReleaseAfterRaw();
        }

        {
            var fixture = new CoordinatorFixture();
            fixture.Pipeline.BlockAfterRaw = true;
            True((await fixture.Coordinator.StartCaptureAsync(false, null)).Started,
                "cancel-during-cleanup fixture starts capture");
            var recordingId = fixture.Store.RecordingId;
            var stopTask = fixture.Coordinator.StopAndTranscribeAsync(TimeSpan.FromSeconds(5));
            await fixture.Pipeline.AfterRawEntered.Task.WaitAsync(TimeSpan.FromSeconds(1));
            await fixture.Coordinator.CancelAsync("cancel optional cleanup");
            Equal("Idle", fixture.State.Current,
                "cancel during optional cleanup releases UI immediately");
            await WaitUntilAsync(
                () => fixture.History.Get(recordingId)?.Status ==
                    AIDictation.Models.TranscriptionStatus.Success,
                TimeSpan.FromSeconds(1));
            Equal("complete raw transcript",
                fixture.History.Get(recordingId)!.Transcription,
                "cancel during optional cleanup preserves durable raw as final");
            await WaitUntilAsync(() => fixture.Usage.Calls == 1, TimeSpan.FromSeconds(1));
            True(fixture.Usage.ReportedAfterTerminalRelease,
                "raw fallback usage is reported only after terminal release");
            fixture.Pipeline.ReleaseAfterRaw();
            True(!(await stopTask.WaitAsync(TimeSpan.FromSeconds(1))).IsSuccess,
                "cancelled cleanup cannot deliver a late cleaned result");
        }

        {
            var fixture = new CoordinatorFixture();
            fixture.Pipeline.BlockAfterRaw = true;
            True((await fixture.Coordinator.StartCaptureAsync(false, null)).Started,
                "shutdown-during-cleanup fixture starts capture");
            var recordingId = fixture.Store.RecordingId;
            var stopTask = fixture.Coordinator.StopAndTranscribeAsync(TimeSpan.FromSeconds(5));
            await fixture.Pipeline.AfterRawEntered.Task.WaitAsync(TimeSpan.FromSeconds(1));
            await fixture.Coordinator
                .ShutdownAsync(TimeSpan.FromSeconds(1))
                .WaitAsync(TimeSpan.FromSeconds(1));
            Equal(AIDictation.Models.TranscriptionStatus.Success,
                fixture.History.Get(recordingId)!.Status,
                "shutdown during optional cleanup keeps durable raw successful");
            Equal("complete raw transcript",
                fixture.History.Get(recordingId)!.Transcription,
                "shutdown never downgrades complete raw recognition");
            Equal(0, fixture.Usage.Calls,
                "shutdown does not report usage before the next exact History recovery");
            await fixture.Coordinator.RecoverOnLaunchAsync();
            Equal(1, fixture.Usage.Calls,
                "launch claims pending raw-fallback usage exactly once after History");
            fixture.Pipeline.ReleaseAfterRaw();
            _ = await stopTask.WaitAsync(TimeSpan.FromSeconds(1));
        }

        {
            var fixture = new CoordinatorFixture();
            fixture.Pipeline.BlockSynchronouslyBeforeTask = true;
            True((await fixture.Coordinator.StartCaptureAsync(false, null)).Started,
                "synchronous-native-block fixture starts capture");
            var stopTask = fixture.Coordinator.StopAndTranscribeAsync(TimeSpan.FromSeconds(5));
            True(fixture.Pipeline.SynchronousSetupEntered.Wait(TimeSpan.FromSeconds(1)),
                "native setup entered its synchronous pre-Task block");
            var result = await stopTask.WaitAsync(TimeSpan.FromSeconds(1));
            True(!result.IsSuccess,
                "coordinator deadline arms before synchronous native setup can block Task creation");
            Equal("Error", fixture.State.Current,
                "synchronous native setup timeout releases the UI with an error");
            fixture.Pipeline.ReleaseSynchronousSetup();
        }

        {
            var fixture = new CoordinatorFixture();
            True((await fixture.Coordinator.StartCaptureAsync(false, null)).Started,
                "initial-recognition race fixture starts capture");
            fixture.Store.BlockBeginRecognition = true;
            var stopTask = fixture.Coordinator.StopAndTranscribeAsync(TimeSpan.FromSeconds(5));
            await fixture.Store.BeginRecognitionEntered.Task.WaitAsync(TimeSpan.FromSeconds(1));
            var result = await stopTask.WaitAsync(TimeSpan.FromSeconds(1));
            True(!result.IsSuccess,
                "initial recognition start returns at the store deadline when its commit is blocked");
            Equal("Error", fixture.State.Current,
                "timed-out initial recognition start releases foreground UI");
            True(!fixture.Coordinator.HasActiveAttempt,
                "timed-out initial recognition start releases its owner");
            fixture.Store.ReleaseBeginRecognition();
            await WaitUntilAsync(
                () => fixture.Store.LastStage == AudioProcessingStage.Failed,
                TimeSpan.FromSeconds(1));
            Equal(AudioProcessingStage.Failed, fixture.Store.LastStage,
                "late initial recognition commit is terminalized in-session");
            Equal(0, fixture.Usage.Calls,
                "timed-out initial recognition never consumes usage");
        }

        {
            var fixture = new CoordinatorFixture();
            var retryPath = Path.Combine(Path.GetTempPath(), $"retry-{Guid.NewGuid():N}.wav");
            await File.WriteAllBytesAsync(retryPath, new byte[] { 1 });
            try
            {
                var retryId = Guid.NewGuid();
                await fixture.History.UpsertAsync(new AIDictation.Models.Recording
                {
                    Id = retryId,
                    AudioFilePath = retryPath,
                    Transcription = "previous complete transcript",
                    Status = AIDictation.Models.TranscriptionStatus.Failed,
                    SourceIntegrity = AIDictation.Models.RecordingSourceIntegrity.Complete,
                    Revision = 1
                });
                fixture.Store.BlockBeginRecognition = true;
                var retryTask = fixture.Coordinator.RetryAsync(retryId, "local");
                await fixture.Store.BeginRecognitionEntered.Task.WaitAsync(TimeSpan.FromSeconds(1));
                True(!(await retryTask.WaitAsync(TimeSpan.FromSeconds(1))).IsSuccess,
                    "retry start returns at the store deadline when its commit is blocked");
                fixture.Store.ReleaseBeginRecognition();
                await WaitUntilAsync(
                    () => fixture.Store.LastStage == AudioProcessingStage.Failed,
                    TimeSpan.FromSeconds(1));
                Equal("previous complete transcript", fixture.History.Get(retryId)!.Transcription,
                    "late retry start is terminalized without replacing the prior complete transcript");
            }
            finally
            {
                try { File.Delete(retryPath); } catch { }
            }
        }

        {
            var fixture = new CoordinatorFixture();
            fixture.Store.BlockComplete = true;
            True((await fixture.Coordinator.StartCaptureAsync(false, null)).Started,
                "terminal-write race fixture starts capture");
            var stopTask = fixture.Coordinator.StopAndTranscribeAsync(TimeSpan.FromSeconds(5));
            await fixture.Store.CompleteEntered.Task.WaitAsync(TimeSpan.FromSeconds(1));
            var result = await stopTask.WaitAsync(TimeSpan.FromSeconds(1));
            True(!result.IsSuccess, "blocked terminal commit ends at the shared deadline");
            Equal("Error", fixture.State.Current,
                "blocked terminal commit releases the UI and keeps launch recovery authoritative");
            True(!fixture.Coordinator.HasActiveAttempt,
                "blocked terminal commit does not strand an active owner");
            Equal(0, fixture.Usage.Calls,
                "a transcript that did not durably complete never consumes usage");
            fixture.Store.ReleaseComplete();
        }

        {
            var fixture = new CoordinatorFixture();
            True((await fixture.Coordinator.StartCaptureAsync(false, null)).Started,
                "blocked-History fixture starts capture");
            fixture.History.BlockUpsert = true;
            fixture.History.BlockUpsertStatus = AIDictation.Models.TranscriptionStatus.Success;
            var stopTask = fixture.Coordinator.StopAndTranscribeAsync(TimeSpan.FromSeconds(5));
            await fixture.History.BlockedUpsertEntered.Task.WaitAsync(TimeSpan.FromSeconds(1));
            var result = await stopTask.WaitAsync(TimeSpan.FromSeconds(1));
            True(!result.IsSuccess,
                "blocked History persistence returns at the shared foreground deadline");
            Equal("Error", fixture.State.Current,
                "blocked History persistence releases UI with recovery guidance");
            True(!fixture.Coordinator.HasActiveAttempt,
                "blocked History persistence cannot strand foreground ownership");
            Equal(0, fixture.Usage.Calls,
                "usage waits for durable History persistence");
            fixture.History.ReleaseUpsert();
            await WaitUntilAsync(
                () => fixture.History.Get(fixture.Store.RecordingId)?.Status ==
                      AIDictation.Models.TranscriptionStatus.Success,
                TimeSpan.FromSeconds(1));
            Equal("complete raw transcript",
                fixture.History.Get(fixture.Store.RecordingId)!.Transcription,
                "late durable History completion reconciles the terminal revision");
            Equal(0, fixture.Usage.Calls,
                "late History completion does not bypass durable startup usage claiming");
        }

        {
            var fixture = new CoordinatorFixture();
            fixture.Pipeline.BlockAfterRaw = true;
            fixture.History.RejectUpsert = true;
            fixture.History.RejectUpsertStatus =
                AIDictation.Models.TranscriptionStatus.Success;
            True((await fixture.Coordinator.StartCaptureAsync(false, null)).Started,
                "raw-timeout History-failure fixture starts capture");
            var stopTask = fixture.Coordinator.StopAndTranscribeAsync(TimeSpan.FromSeconds(5));
            await fixture.Pipeline.AfterRawEntered.Task.WaitAsync(TimeSpan.FromSeconds(1));
            var result = await stopTask.WaitAsync(TimeSpan.FromSeconds(1));
            True(!result.IsSuccess,
                "authoritative raw fallback reports truthful retryable failure when History rejects it");
            Equal(UsageAccountingState.Pending, fixture.Store.UsageState,
                "raw fallback preserves pending usage eligibility when History is not durable");
            Equal(0, fixture.Store.ClaimUsageCalls,
                "raw fallback never irrevocably claims usage before durable History");
            Equal(0, fixture.Usage.Calls,
                "raw fallback History failure never reaches the usage sink");
            fixture.Pipeline.ReleaseAfterRaw();

            fixture.History.RejectUpsert = false;
            var recoveredCoordinator = new AudioProcessingCoordinator(
                fixture.Store,
                fixture.Recorder,
                fixture.Pipeline,
                fixture.History,
                fixture.State,
                new AudioCoordinatorDeadlines(
                    TimeSpan.FromMilliseconds(40),
                    TimeSpan.FromMilliseconds(150),
                    TimeSpan.FromMilliseconds(250)),
                fixture.Usage);
            await recoveredCoordinator.RecoverOnLaunchAsync();
            Equal(UsageAccountingState.Claimed, fixture.Store.UsageState,
                "startup claims raw-fallback usage only after History publication succeeds");
            Equal(1, fixture.Usage.Calls,
                "startup dispatches a recovered raw transcript exactly once");
            await recoveredCoordinator.RecoverOnLaunchAsync();
            Equal(1, fixture.Usage.Calls,
                "claimed startup usage is not sent again on another launch recovery");
        }

        {
            var fixture = new CoordinatorFixture();
            var recordingId = Guid.NewGuid();
            fixture.Store.SeedPendingSuccess(recordingId, "startup pending transcript");
            fixture.History.RejectUpsert = true;
            fixture.History.RejectUpsertStatus =
                AIDictation.Models.TranscriptionStatus.Success;
            await fixture.Coordinator.RecoverOnLaunchAsync();
            Equal(0, fixture.Store.ClaimUsageCalls,
                "startup History rejection leaves durable usage pending and unclaimed");
            Equal(0, fixture.Usage.Calls,
                "startup History rejection never bills an inaccessible transcript");
            Equal(UsageAccountingState.Pending, fixture.Store.UsageState,
                "startup preserves usage eligibility for a later durable History repair");
        }

        {
            var fixture = new CoordinatorFixture();
            var started = await fixture.Coordinator.StartCaptureAsync(false, null);
            True(started.Started && started.RecordingId.HasValue,
                "delete-vs-late-History fixture starts capture");
            fixture.History.BlockUpsert = true;
            fixture.History.BlockUpsertStatus = AIDictation.Models.TranscriptionStatus.Cancelled;
            await fixture.Coordinator.CancelAsync("cancel before delete");
            await fixture.History.BlockedUpsertEntered.Task.WaitAsync(TimeSpan.FromSeconds(1));
            var deleted = await fixture.Coordinator.DeleteAsync(started.RecordingId!.Value);
            True(deleted.Deleted,
                "Delete commits while detached terminal History publication is blocked");
            fixture.History.ReleaseUpsert();
            await fixture.History.BlockedUpsertFinished.Task.WaitAsync(TimeSpan.FromSeconds(1));
            True(fixture.History.Get(started.RecordingId.Value) == null,
                "late terminal History publication cannot recreate a deleted row");
        }

        {
            var fixture = new CoordinatorFixture();
            var started = await fixture.Coordinator.StartCaptureAsync(false, null);
            True(started.Started && started.RecordingId.HasValue,
                "Clear-vs-late-History fixture starts capture");
            fixture.History.BlockUpsert = true;
            fixture.History.BlockUpsertStatus = AIDictation.Models.TranscriptionStatus.Cancelled;
            await fixture.Coordinator.CancelAsync("cancel before Clear");
            await fixture.History.BlockedUpsertEntered.Task.WaitAsync(TimeSpan.FromSeconds(1));
            var cleared = await fixture.Coordinator.ClearAsync();
            True(cleared.Cleared,
                "Clear commits while detached terminal History publication is blocked");
            fixture.History.ReleaseUpsert();
            await fixture.History.BlockedUpsertFinished.Task.WaitAsync(TimeSpan.FromSeconds(1));
            True(fixture.History.Get(started.RecordingId!.Value) == null,
                "late terminal History publication cannot recreate a cleared row");
        }

        {
            var fixture = new CoordinatorFixture();
            var deletedId = Guid.NewGuid();
            fixture.Store.SeedTerminal(deletedId);
                await fixture.History.UpsertAsync(new AIDictation.Models.Recording
            {
                Id = deletedId,
                Transcription = "delete after durable tombstone",
                Status = AIDictation.Models.TranscriptionStatus.Success,
                SourceIntegrity = AIDictation.Models.RecordingSourceIntegrity.Complete,
                Revision = 1
            });
            fixture.Store.BlockTombstone = true;
            var deleteTask = fixture.Coordinator.DeleteAsync(deletedId);
            await fixture.Store.TombstoneEntered.Task.WaitAsync(TimeSpan.FromSeconds(1));
            var deleteResult = await deleteTask.WaitAsync(TimeSpan.FromSeconds(1));
            True(!deleteResult.Deleted && fixture.History.Get(deletedId) != null,
                "delete timeout keeps visible metadata until its durable tombstone commits");
            fixture.Store.ReleaseTombstone();
            await WaitUntilAsync(() => fixture.History.Get(deletedId) == null, TimeSpan.FromSeconds(1));
            True(fixture.History.Get(deletedId) == null,
                "late durable tombstone reconciles History without requiring restart");
        }

        {
            var fixture = new CoordinatorFixture();
            var oldId = Guid.NewGuid();
            var newerId = Guid.NewGuid();
            await fixture.History.UpsertAsync(new AIDictation.Models.Recording
            {
                Id = oldId,
                Transcription = "clear me",
                Status = AIDictation.Models.TranscriptionStatus.Success,
                SourceIntegrity = AIDictation.Models.RecordingSourceIntegrity.Complete,
                Revision = 1
            });
            fixture.Store.BlockClear = true;
            var clearTask = fixture.Coordinator.ClearAsync();
            await fixture.Store.ClearEntered.Task.WaitAsync(TimeSpan.FromSeconds(1));
            var clearResult = await clearTask.WaitAsync(TimeSpan.FromSeconds(1));
            True(!clearResult.Cleared && fixture.History.Get(oldId) != null,
                "Clear timeout keeps visible metadata until its durable tombstones commit");
            await fixture.History.UpsertAsync(new AIDictation.Models.Recording
            {
                Id = newerId,
                Transcription = "created after timed-out Clear",
                Status = AIDictation.Models.TranscriptionStatus.Success,
                SourceIntegrity = AIDictation.Models.RecordingSourceIntegrity.Complete,
                Revision = 1
            });
            fixture.Store.ReleaseClear();
            await WaitUntilAsync(() => fixture.History.Get(oldId) == null, TimeSpan.FromSeconds(1));
            True(fixture.History.Get(newerId) != null,
                "late Clear reconciliation removes only rows that existed before Clear began");
        }

        {
            var fixture = new CoordinatorFixture();
            var visibleId = Guid.NewGuid();
            var storeOnlyId = Guid.NewGuid();
            var postClearId = Guid.NewGuid();
            fixture.Store.SeedTerminal(visibleId);
            fixture.Store.AdditionalClearAffectedIds = new[] { storeOnlyId };
            await fixture.History.UpsertAsync(new AIDictation.Models.Recording
            {
                Id = visibleId,
                Transcription = "visible before exact-set clear",
                Status = AIDictation.Models.TranscriptionStatus.Success,
                SourceIntegrity = AIDictation.Models.RecordingSourceIntegrity.Complete,
                Revision = 1
            });
            fixture.History.BlockUpsert = true;
            var hiddenLateUpsert = fixture.History.UpsertAsync(new AIDictation.Models.Recording
            {
                Id = storeOnlyId,
                Transcription = "late hidden store row",
                Status = AIDictation.Models.TranscriptionStatus.Cancelled,
                SourceIntegrity = AIDictation.Models.RecordingSourceIntegrity.Complete,
                Revision = 2
            });
            await fixture.History.BlockedUpsertEntered.Task.WaitAsync(TimeSpan.FromSeconds(1));

            var cleared = await fixture.Coordinator.ClearAsync();
            True(cleared.Cleared,
                "Clear atomically fences the exact union of Store and History ids");
            Equal(1, fixture.History.BatchTombstoneCalls,
                "Clear commits one atomic History tombstone batch");
            True(fixture.History.LastBatchTombstoneIds.Contains(visibleId) &&
                 fixture.History.LastBatchTombstoneIds.Contains(storeOnlyId),
                "Clear batch includes a Store-only id absent from the pre-Clear History snapshot");

            fixture.History.ReleaseUpsert();
            True(!await hiddenLateUpsert.WaitAsync(TimeSpan.FromSeconds(1)),
                "late publication of a Store-only cleared id is rejected");
            True(fixture.History.Get(storeOnlyId) == null,
                "Store-only cleared metadata cannot reappear");
            True(await fixture.History.UpsertAsync(new AIDictation.Models.Recording
            {
                Id = postClearId,
                Transcription = "created after exact-set clear",
                Status = AIDictation.Models.TranscriptionStatus.Success,
                SourceIntegrity = AIDictation.Models.RecordingSourceIntegrity.Complete,
                Revision = 1
            }),
                "post-Clear ids remain publishable");
            True(fixture.History.Get(postClearId) != null,
                "exact-set Clear never removes a post-Clear row");
        }

        {
            var fixture = new CoordinatorFixture();
            fixture.Store.BlockClaimUsage = true;
            True((await fixture.Coordinator.StartCaptureAsync(false, null)).Started,
                "usage-stall fixture starts capture");
            var stopTask = fixture.Coordinator.StopAndTranscribeAsync(TimeSpan.FromSeconds(5));
            await fixture.Store.ClaimUsageEntered.Task.WaitAsync(TimeSpan.FromSeconds(1));
            Equal("Result", fixture.State.Current,
                "durable terminal text reaches Result before usage accounting finishes");
            True(!fixture.Coordinator.HasActiveAttempt,
                "stalled usage accounting cannot retain foreground processing ownership");
            var result = await stopTask.WaitAsync(TimeSpan.FromSeconds(1));
            True(result.IsSuccess,
                "bounded usage-accounting timeout cannot undo a durable successful transcript");
            Equal(0, fixture.Usage.Calls,
                "usage is not reported before its durable claim commits");
            fixture.Store.ReleaseClaimUsage();
            await WaitUntilAsync(() => fixture.Usage.Calls == 1, TimeSpan.FromSeconds(1));
            Equal(1, fixture.Usage.Calls,
                "late durable usage claim reconciles exactly once outside processing ownership");
        }

        {
            var fixture = new CoordinatorFixture();
            fixture.Recorder.StopDelay = TimeSpan.FromMilliseconds(75);
            True((await fixture.Coordinator.StartCaptureAsync(false, null)).Started,
                "maximum-duration fixture starts capture");
            var result = await fixture.Coordinator
                .StopAndTranscribeAsync(TimeSpan.FromMinutes(20))
                .WaitAsync(TimeSpan.FromSeconds(1));
            True(result.IsSuccess,
                "maximum-duration recording receives finalization grace before recognition deadline starts");
            Equal("Result", fixture.State.Current,
                "successful maximum-duration finalization reaches a terminal result state");
            Equal(1, fixture.Usage.Calls,
                "successful durable completion reports usage exactly once");
            True(fixture.Usage.ReportedAfterTerminalRelease,
                "usage reporting runs only after Result and foreground ownership release");
        }

        {
            var fixture = new CoordinatorFixture();
            True((await fixture.Coordinator.StartCaptureAsync(false, null)).Started,
                "shutdown ordering fixture starts capture");
            fixture.Store.ObserveShutdownOrdering = true;
            fixture.Store.ThrowOnAbandon = true;
            var started = DateTime.UtcNow;
            await fixture.Coordinator
                .ShutdownAsync(TimeSpan.FromMilliseconds(120))
                .WaitAsync(TimeSpan.FromSeconds(1));
            True(DateTime.UtcNow - started < TimeSpan.FromMilliseconds(500),
                "corrupt terminal store cannot extend the one total exit deadline");
            True(!fixture.Store.StoreTouchedBeforeRecorderShutdown,
                "shutdown initiates and fences native writer close before store terminalization");
            Equal(0, fixture.Store.GetCalls,
                "shutdown never reads the store before writer finalization");
            Equal("Idle", fixture.State.Current,
                "corrupt shutdown persistence still returns foreground state to idle");
            Equal(0, fixture.Usage.Calls,
                "shutdown never bills a nonterminal recording");
            await fixture.Coordinator.ShutdownAsync(TimeSpan.FromSeconds(10));
            Equal(1, fixture.Recorder.ShutdownCalls,
                "repeated shutdown is idempotent and adds no second recorder budget");
        }

        {
            var fixture = new CoordinatorFixture();
            True((await fixture.Coordinator.StartCaptureAsync(false, null)).Started,
                "wedged-writer shutdown fixture starts capture");
            fixture.Recorder.BlockShutdown = true;
            fixture.Store.ThrowOnAbandon = true;
            var started = DateTime.UtcNow;
            await fixture.Coordinator
                .ShutdownAsync(TimeSpan.FromMilliseconds(80))
                .WaitAsync(TimeSpan.FromSeconds(1));
            True(DateTime.UtcNow - started < TimeSpan.FromMilliseconds(500),
                "wedged native writer consumes at most the shared exit deadline");
            Equal(1, fixture.Recorder.ShutdownCalls,
                "wedged writer has one stable shutdown owner");
            Equal(0, fixture.Store.GetCalls,
                "wedged writer shutdown performs no pre-finalization store read");
            Equal(0, fixture.Usage.Calls,
                "wedged writer plus unavailable store cannot bill usage");
            fixture.Recorder.ReleaseShutdown();
        }
    }

    private static TranscriptionAttemptSnapshot Snapshot(string provider, string context) => new(
        provider,
        new[] { "en" },
        "recognition",
        "cleanup",
        true,
        new[] { new TextReplacementSnapshot("old", "new") },
        new[] { new TextReplacementSnapshot("shortcut", "expanded") },
        context);

    private static AudioHttpRecoveryPolicy NoWaitPolicy() =>
        new((_, _) => Task.CompletedTask);

    private static HttpResponseMessage Response(HttpStatusCode status, string body) => new(status)
    {
        Content = new StringContent(body)
    };

    private static void WriteWave(string path, int dataBytes)
    {
        using var stream = new FileStream(path, FileMode.Create, FileAccess.Write, FileShare.Read);
        using var writer = new BinaryWriter(stream);
        writer.Write(System.Text.Encoding.ASCII.GetBytes("RIFF"));
        writer.Write((uint)(36 + dataBytes));
        writer.Write(System.Text.Encoding.ASCII.GetBytes("WAVE"));
        writer.Write(System.Text.Encoding.ASCII.GetBytes("fmt "));
        writer.Write((uint)16);
        writer.Write((ushort)1);
        writer.Write((ushort)1);
        writer.Write((uint)16_000);
        writer.Write((uint)32_000);
        writer.Write((ushort)2);
        writer.Write((ushort)16);
        writer.Write(System.Text.Encoding.ASCII.GetBytes("data"));
        writer.Write((uint)dataBytes);
        writer.Write(new byte[dataBytes]);
        writer.Flush();
        stream.Flush(flushToDisk: true);
    }

    private static void True(bool condition, string message)
    {
        _assertions++;
        if (!condition) throw new InvalidOperationException($"FAIL: {message}");
    }

    private static void Equal<T>(T expected, T actual, string message)
    {
        _assertions++;
        if (!EqualityComparer<T>.Default.Equals(expected, actual))
            throw new InvalidOperationException($"FAIL: {message}. Expected {expected}, got {actual}");
    }

    private static void SequenceEqual<T>(IEnumerable<T> expected, IEnumerable<T> actual, string message)
    {
        _assertions++;
        if (!expected.SequenceEqual(actual))
            throw new InvalidOperationException(
                $"FAIL: {message}. Expected [{string.Join(",", expected)}], got [{string.Join(",", actual)}]");
    }

    private static void Throws<TException>(Action action) where TException : Exception
    {
        _assertions++;
        try { action(); }
        catch (TException) { return; }
        throw new InvalidOperationException($"FAIL: expected {typeof(TException).Name}");
    }

    private static async Task ThrowsAsync<TException>(Func<Task> action) where TException : Exception
    {
        _assertions++;
        try { await action(); }
        catch (TException) { return; }
        throw new InvalidOperationException($"FAIL: expected {typeof(TException).Name}");
    }

    private static async Task WaitUntilAsync(Func<bool> condition, TimeSpan timeout)
    {
        var deadline = DateTime.UtcNow + timeout;
        while (!condition())
        {
            if (DateTime.UtcNow >= deadline)
                throw new TimeoutException("Contract condition did not become true in time.");
            await Task.Delay(5);
        }
    }

    private sealed class CoordinatorFixture
    {
        public FakeCoordinatorStore Store { get; } = new();
        public FakeRecorder Recorder { get; } = new();
        public FakePipeline Pipeline { get; } = new();
        public FakeHistory History { get; } = new();
        public FakeAppState State { get; } = new();
        public FakeUsageReporter Usage { get; } = new();
        public AudioProcessingCoordinator Coordinator { get; }

        public CoordinatorFixture()
        {
            Coordinator = new AudioProcessingCoordinator(
                Store,
                Recorder,
                Pipeline,
                History,
                State,
                new AudioCoordinatorDeadlines(
                    TimeSpan.FromMilliseconds(40),
                    TimeSpan.FromMilliseconds(150),
                    TimeSpan.FromMilliseconds(250)),
                Usage);
            Usage.IsTerminalAndReleased = () =>
                State.Current is "Result" or "Idle" && !Coordinator.HasActiveAttempt;
            Store.RecorderShutdownStarted = () => Recorder.ShutdownCalls > 0;
        }
    }

    private sealed class FakeCoordinatorStore : IAudioProcessingStore
    {
        private readonly object _lock = new();
        private readonly TaskCompletionSource<bool> _beginCaptureRelease = NewSignal();
        private readonly TaskCompletionSource<bool> _captureBecameReadyRelease = NewSignal();
        private readonly TaskCompletionSource<bool> _beginRecognitionRelease = NewSignal();
        private readonly TaskCompletionSource<bool> _beginFinalizationRelease = NewSignal();
        private readonly TaskCompletionSource<bool> _checkpointRelease = NewSignal();
        private readonly TaskCompletionSource<bool> _completeRelease = NewSignal();
        private readonly TaskCompletionSource<bool> _claimUsageRelease = NewSignal();
        private readonly TaskCompletionSource<bool> _tombstoneRelease = NewSignal();
        private readonly TaskCompletionSource<bool> _clearRelease = NewSignal();
        private Guid _recordingId;
        private Guid _attemptId;
        private long _revision;
        private AudioProcessingEntry? _entry;

        public bool BlockBeginCapture { get; set; }
        public bool BlockCaptureBecameReady { get; set; }
        public bool BlockBeginRecognition { get; set; }
        public bool BlockBeginFinalization { get; set; }
        public bool BlockCheckpoint { get; set; }
        public bool BlockComplete { get; set; }
        public bool BlockClaimUsage { get; set; }
        public bool BlockTombstone { get; set; }
        public bool BlockClear { get; set; }
        public bool ThrowOnAbandon { get; set; }
        public bool ObserveShutdownOrdering { get; set; }
        public Func<bool>? RecorderShutdownStarted { get; set; }
        public bool StoreTouchedBeforeRecorderShutdown { get; private set; }
        public int ClaimUsageCalls;
        public int GetCalls;
        public IReadOnlyCollection<Guid> AdditionalClearAffectedIds { get; set; } =
            Array.Empty<Guid>();
        public TaskCompletionSource<bool> BeginCaptureEntered { get; } = NewSignal();
        public TaskCompletionSource<bool> CaptureBecameReadyEntered { get; } = NewSignal();
        public TaskCompletionSource<bool> BeginRecognitionEntered { get; } = NewSignal();
        public TaskCompletionSource<bool> BeginFinalizationEntered { get; } = NewSignal();
        public TaskCompletionSource<bool> CheckpointEntered { get; } = NewSignal();
        public TaskCompletionSource<bool> CompleteEntered { get; } = NewSignal();
        public TaskCompletionSource<bool> ClaimUsageEntered { get; } = NewSignal();
        public TaskCompletionSource<bool> TombstoneEntered { get; } = NewSignal();
        public TaskCompletionSource<bool> ClearEntered { get; } = NewSignal();
        public bool PersistenceHealthy => true;
        public Guid RecordingId
        {
            get { lock (_lock) return _recordingId; }
        }
        public AudioAttemptLease? CurrentLease
        {
            get
            {
                lock (_lock)
                {
                    return _entry?.AttemptId is Guid attemptId
                        ? new AudioAttemptLease(
                            _entry.RecordingId,
                            attemptId,
                            _entry.DeletionGeneration,
                            _entry.ClearGeneration,
                            _entry.Revision)
                        : null;
                }
            }
        }
        public AudioProcessingStage? LastStage
        {
            get { lock (_lock) return _entry?.Stage; }
        }
        public UsageAccountingState? UsageState
        {
            get { lock (_lock) return _entry?.UsageAccounting; }
        }
        public bool FinalizationProven
        {
            get { lock (_lock) return _entry?.FinalizationProven == true; }
        }

        public void ReleaseBeginCapture() => _beginCaptureRelease.TrySetResult(true);
        public void ReleaseCaptureBecameReady() => _captureBecameReadyRelease.TrySetResult(true);
        public void ReleaseBeginRecognition() => _beginRecognitionRelease.TrySetResult(true);
        public void ReleaseBeginFinalization() => _beginFinalizationRelease.TrySetResult(true);
        public void ReleaseCheckpoint() => _checkpointRelease.TrySetResult(true);
        public void ReleaseComplete() => _completeRelease.TrySetResult(true);
        public void ReleaseClaimUsage() => _claimUsageRelease.TrySetResult(true);
        public void ReleaseTombstone() => _tombstoneRelease.TrySetResult(true);
        public void ReleaseClear() => _clearRelease.TrySetResult(true);

        public void SeedTerminal(Guid recordingId)
        {
            lock (_lock)
            {
                _recordingId = recordingId;
                _attemptId = Guid.NewGuid();
                _revision = 0;
                _ = Transition(AudioProcessingStage.Failed, integrity: AudioSourceIntegrity.Complete);
            }
        }

        public void SeedPendingSuccess(Guid recordingId, string text)
        {
            lock (_lock)
            {
                _recordingId = recordingId;
                _attemptId = Guid.NewGuid();
                _revision = 0;
                var result = Transition(
                    AudioProcessingStage.Succeeded,
                    integrity: AudioSourceIntegrity.Complete);
                result.Entry!.FinalText = text;
                result.Entry.RawText = text;
                result.Entry.UsageAccounting = UsageAccountingState.Pending;
            }
        }

        public async Task<AudioStoreMutation> BeginCaptureAsync(
            TranscriptionAttemptSnapshot snapshot,
            Guid? requestedRecordingId = null,
            CancellationToken cancellationToken = default)
        {
            BeginCaptureEntered.TrySetResult(true);
            if (BlockBeginCapture) await _beginCaptureRelease.Task.ConfigureAwait(false);
            lock (_lock)
            {
                _recordingId = requestedRecordingId ?? Guid.NewGuid();
                _attemptId = Guid.NewGuid();
                _revision = 0;
                return Transition(AudioProcessingStage.Preparing, snapshot, AudioSourceIntegrity.Unfinalized);
            }
        }

        public async Task<AudioStoreMutation> CaptureBecameReadyAsync(
            AudioAttemptLease lease,
            CancellationToken cancellationToken = default)
        {
            CaptureBecameReadyEntered.TrySetResult(true);
            if (BlockCaptureBecameReady)
                await _captureBecameReadyRelease.Task.ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            return Transition(
                AudioProcessingStage.Recording,
                integrity: AudioSourceIntegrity.Unfinalized);
        }

        public Task<AudioStoreMutation> AdoptFinalizedCaptureAsync(
            AudioAttemptLease lease,
            RecorderFinalizationResult proof,
            CancellationToken cancellationToken = default)
        {
            lock (_lock)
            {
                if (_entry == null ||
                    _entry.RecordingId != lease.RecordingId ||
                    _entry.AttemptId != lease.AttemptId ||
                    _entry.DeletionGeneration != lease.DeletionGeneration ||
                    _entry.ClearGeneration != lease.ClearGeneration ||
                    _entry.Stage == AudioProcessingStage.Deleted ||
                    !proof.IsFinalized)
                {
                    return Task.FromResult(new AudioStoreMutation(
                        false,
                        null,
                        _entry,
                        "Attempt is stale"));
                }
                var stage = _entry.Stage is AudioProcessingStage.Cancelled or AudioProcessingStage.Failed
                    ? _entry.Stage
                    : AudioProcessingStage.ReadyForRecognition;
                var adopted = Transition(
                    stage,
                    integrity: AudioSourceIntegrity.Complete);
                adopted.Entry!.FinalizationProven = true;
                return Task.FromResult(adopted);
            }
        }

        public Task<AudioStoreMutation> RecordCaptureKnownIncompleteAsync(
            AudioAttemptLease lease,
            string message,
            CancellationToken cancellationToken = default)
        {
            lock (_lock)
            {
                if (_entry == null ||
                    _entry.RecordingId != lease.RecordingId ||
                    _entry.AttemptId != lease.AttemptId ||
                    _entry.DeletionGeneration != lease.DeletionGeneration ||
                    _entry.ClearGeneration != lease.ClearGeneration ||
                    _entry.Stage == AudioProcessingStage.Deleted)
                {
                    return Task.FromResult(new AudioStoreMutation(
                        false,
                        null,
                        _entry,
                        "Attempt is stale"));
                }
                var stage = _entry.Stage is AudioProcessingStage.Cancelled or AudioProcessingStage.Failed
                    ? _entry.Stage
                    : AudioProcessingStage.Failed;
                var result = Transition(stage, integrity: AudioSourceIntegrity.KnownIncomplete);
                result.Entry!.FinalizationProven = false;
                result.Entry.ErrorMessage = message;
                return Task.FromResult(result);
            }
        }

        public async Task<AudioStoreMutation> BeginFinalizationAsync(
            AudioAttemptLease lease,
            CancellationToken cancellationToken = default)
        {
            if (ObserveShutdownOrdering && RecorderShutdownStarted?.Invoke() != true)
                StoreTouchedBeforeRecorderShutdown = true;
            BeginFinalizationEntered.TrySetResult(true);
            if (BlockBeginFinalization) await _beginFinalizationRelease.Task.ConfigureAwait(false);
            return Transition(AudioProcessingStage.Finalizing, integrity: AudioSourceIntegrity.Unfinalized);
        }

        public async Task<AudioStoreMutation> BeginRecognitionAsync(
            Guid recordingId,
            TranscriptionAttemptSnapshot snapshot,
            CancellationToken cancellationToken = default)
        {
            BeginRecognitionEntered.TrySetResult(true);
            if (BlockBeginRecognition)
                await _beginRecognitionRelease.Task.ConfigureAwait(false);
            lock (_lock)
            {
                _recordingId = recordingId;
                _attemptId = Guid.NewGuid();
                return Transition(
                    AudioProcessingStage.Recognizing,
                    snapshot,
                    AudioSourceIntegrity.Complete);
            }
        }

        public async Task<AudioStoreMutation> SaveCheckpointAsync(
            AudioAttemptLease lease,
            string orderedText,
            int completedLeafCount,
            CancellationToken cancellationToken = default)
        {
            CheckpointEntered.TrySetResult(true);
            if (BlockCheckpoint) await _checkpointRelease.Task.ConfigureAwait(false);
            var result = Transition(AudioProcessingStage.Recognizing, integrity: AudioSourceIntegrity.Complete);
            result.Entry!.CheckpointText = orderedText;
            result.Entry.CompletedLeafCount = completedLeafCount;
            return result;
        }

        public Task<AudioStoreMutation> SaveRawResultAsync(
            AudioAttemptLease lease,
            string rawText,
            CancellationToken cancellationToken = default)
        {
            var result = Transition(AudioProcessingStage.ResultReady, integrity: AudioSourceIntegrity.Complete);
            result.Entry!.RawText = rawText;
            return Task.FromResult(result);
        }

        public async Task<AudioStoreMutation> CompleteAsync(
            AudioAttemptLease lease,
            string finalText,
            CancellationToken cancellationToken = default)
        {
            CompleteEntered.TrySetResult(true);
            if (BlockComplete) await _completeRelease.Task.ConfigureAwait(false);
            var result = Transition(AudioProcessingStage.Succeeded, integrity: AudioSourceIntegrity.Complete);
            result.Entry!.FinalText = finalText;
            result.Entry.UsageAccounting = UsageAccountingState.Pending;
            return result;
        }

        public async Task<AudioUsageClaim?> ClaimUsageAsync(
            Guid recordingId,
            CancellationToken cancellationToken = default)
        {
            Interlocked.Increment(ref ClaimUsageCalls);
            ClaimUsageEntered.TrySetResult(true);
            if (BlockClaimUsage)
                await _claimUsageRelease.Task.ConfigureAwait(false);
            lock (_lock)
            {
                if (_entry?.RecordingId != recordingId ||
                    _entry.Stage != AudioProcessingStage.Succeeded ||
                    _entry.UsageAccounting != UsageAccountingState.Pending ||
                    string.IsNullOrWhiteSpace(_entry.FinalText))
                    return null;
                _entry.UsageAccounting = UsageAccountingState.Claimed;
                return new AudioUsageClaim(recordingId, _entry.FinalText);
            }
        }

        public Task<AudioStoreMutation> FailAsync(
            AudioAttemptLease lease,
            string message,
            AudioSourceIntegrity? integrity = null,
            CancellationToken cancellationToken = default)
        {
            var rawFallback = TryPromoteRawFallback();
            if (rawFallback != null) return Task.FromResult(rawFallback);
            var result = Transition(AudioProcessingStage.Failed, integrity: integrity ?? AudioSourceIntegrity.Complete);
            result.Entry!.ErrorMessage = message;
            return Task.FromResult(result);
        }

        public Task<AudioStoreMutation> CancelAsync(
            AudioAttemptLease lease,
            string message,
            CancellationToken cancellationToken = default)
        {
            var rawFallback = TryPromoteRawFallback();
            return rawFallback != null
                ? Task.FromResult(rawFallback)
                : AbandonAttemptAsync(
                    lease,
                    true,
                    message,
                    AudioSourceIntegrity.Complete,
                    cancellationToken);
        }

        public Task<AudioStoreMutation> AbandonAttemptAsync(
            AudioAttemptLease lease,
            bool cancelled,
            string message,
            AudioSourceIntegrity integrity,
            CancellationToken cancellationToken = default)
        {
            if (ThrowOnAbandon) throw new AudioStoreException("contract store is corrupt");
            var rawFallback = TryPromoteRawFallback();
            if (rawFallback != null) return Task.FromResult(rawFallback);
            var result = Transition(
                cancelled ? AudioProcessingStage.Cancelled : AudioProcessingStage.Failed,
                integrity: integrity);
            result.Entry!.ErrorMessage = message;
            return Task.FromResult(result);
        }

        private AudioStoreMutation? TryPromoteRawFallback()
        {
            lock (_lock)
            {
                if (_entry?.Stage != AudioProcessingStage.ResultReady ||
                    string.IsNullOrWhiteSpace(_entry.RawText))
                    return null;
                var rawFallback = Transition(
                    AudioProcessingStage.Succeeded,
                    integrity: AudioSourceIntegrity.Complete);
                rawFallback.Entry!.FinalText = rawFallback.Entry.RawText;
                rawFallback.Entry.ErrorMessage = null;
                rawFallback.Entry.UsageAccounting ??= UsageAccountingState.Pending;
                return rawFallback;
            }
        }

        public async Task<AudioStoreMutation> TombstoneAsync(
            Guid recordingId,
            CancellationToken cancellationToken = default)
        {
            TombstoneEntered.TrySetResult(true);
            if (BlockTombstone) await _tombstoneRelease.Task.ConfigureAwait(false);
            return Transition(AudioProcessingStage.Deleted);
        }

        public async Task<AudioStoreMutation> ClearAsync(CancellationToken cancellationToken = default)
        {
            ClearEntered.TrySetResult(true);
            if (BlockClear) await _clearRelease.Task.ConfigureAwait(false);
            Guid[] affected;
            lock (_lock)
            {
                var current = _entry == null
                    ? Array.Empty<Guid>()
                    : new[] { _entry.RecordingId };
                affected = current
                    .Concat(AdditionalClearAffectedIds)
                    .Distinct()
                    .ToArray();
                if (_entry != null) _entry.Stage = AudioProcessingStage.Deleted;
            }
            return new AudioStoreMutation(
                true,
                null,
                null,
                AffectedRecordingIds: affected);
        }

        public Task<IReadOnlyList<AudioProcessingEntry>> RecoverOnLaunchAsync(
            CancellationToken cancellationToken = default)
        {
            lock (_lock)
            {
                return Task.FromResult<IReadOnlyList<AudioProcessingEntry>>(
                    _entry == null
                        ? Array.Empty<AudioProcessingEntry>()
                        : new[] { _entry });
            }
        }

        public Task<AudioStoreMutation> ImportLegacyFinalizedSourceAsync(
            Guid recordingId,
            string legacySourcePath,
            string? finalText,
            TranscriptionAttemptSnapshot snapshot,
            CancellationToken cancellationToken = default) =>
            Task.FromResult(new AudioStoreMutation(false, null, null, "not used"));

        public Task<bool> AcceptLegacySourceOwnershipAsync(
            Guid recordingId,
            CancellationToken cancellationToken = default) => Task.FromResult(true);

        public Task<AudioProcessingEntry?> GetAsync(
            Guid recordingId,
            CancellationToken cancellationToken = default)
        {
            Interlocked.Increment(ref GetCalls);
            lock (_lock) return Task.FromResult(_entry);
        }

        private AudioStoreMutation Transition(
            AudioProcessingStage stage,
            TranscriptionAttemptSnapshot? snapshot = null,
            AudioSourceIntegrity integrity = AudioSourceIntegrity.Complete)
        {
            lock (_lock)
            {
                if (_recordingId == Guid.Empty) _recordingId = Guid.NewGuid();
                if (_attemptId == Guid.Empty) _attemptId = Guid.NewGuid();
                _revision++;
                var lease = new AudioAttemptLease(_recordingId, _attemptId, 0, 0, _revision);
                _entry = new AudioProcessingEntry
                {
                    RecordingId = _recordingId,
                    AttemptId = stage is AudioProcessingStage.Succeeded or AudioProcessingStage.Deleted
                        ? null
                        : _attemptId,
                    Revision = _revision,
                    Stage = stage,
                    SourceIntegrity = integrity,
                    PartialSourcePath = Path.Combine(Path.GetTempPath(), $"{_recordingId:N}.partial.wav"),
                    FinalSourcePath = Path.Combine(Path.GetTempPath(), $"{_recordingId:N}.wav"),
                    CreatedUtc = DateTimeOffset.UtcNow,
                    UpdatedUtc = DateTimeOffset.UtcNow,
                    SettingsSnapshot = snapshot ?? _entry?.SettingsSnapshot,
                    FinalText = _entry?.FinalText,
                    RawText = _entry?.RawText,
                    CheckpointText = _entry?.CheckpointText,
                    UsageAccounting = _entry?.UsageAccounting,
                    ErrorMessage = _entry?.ErrorMessage,
                    FinalizationProven = _entry?.FinalizationProven ?? false,
                    DeletionGeneration = _entry?.DeletionGeneration ?? 0,
                    ClearGeneration = _entry?.ClearGeneration ?? 0
                };
                return new AudioStoreMutation(true, lease, _entry);
            }
        }

        private static TaskCompletionSource<bool> NewSignal() =>
            new(TaskCreationOptions.RunContinuationsAsynchronously);
    }

    private sealed class FakeRecorder : IAudioRecorderService
    {
        private EventHandler<RecorderCaptureFailedEventArgs>? _captureTerminated;
        public int StartCalls;
        public int AbortCalls;
        public TimeSpan StopDelay { get; set; }
        public bool BlockAbortProof { get; set; }
        public bool AbortIsFinalized { get; set; } = true;
        public bool BlockShutdown { get; set; }
        public bool ShutdownWaitsForAbortProof { get; set; }
        public int ShutdownCalls;
        public TaskCompletionSource<bool> ShutdownEntered { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource<bool> _shutdownRelease =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly TaskCompletionSource<bool> _abortProofRelease =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource<bool> AbortObserved { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public event EventHandler<RecorderCaptureFailedEventArgs>? CaptureTerminatedUnexpectedly
        {
            add => _captureTerminated += value;
            remove => _captureTerminated -= value;
        }

        public Task<RecorderStartResult> StartRecordingAsync(
            AudioAttemptLease lease,
            string partialSourcePath,
            string? selectedDeviceId,
            CancellationToken cancellationToken)
        {
            Interlocked.Increment(ref StartCalls);
            return Task.FromResult(RecorderStartResult.Ready());
        }

        public async Task<RecorderFinalizationResult> StopRecordingAsync(
            AudioAttemptLease lease,
            TimeSpan? deadline = null,
            CancellationToken cancellationToken = default)
        {
            if (StopDelay > TimeSpan.Zero) await Task.Delay(StopDelay, cancellationToken);
            return new RecorderFinalizationResult(true, "contract.partial.wav", null);
        }

        public async Task<RecorderFinalizationResult?> AbortRecordingAsync(
            AudioAttemptLease lease,
            string reason,
            TimeSpan? deadline = null,
            CancellationToken cancellationToken = default)
        {
            Interlocked.Increment(ref AbortCalls);
            AbortObserved.TrySetResult(true);
            if (BlockAbortProof)
                await _abortProofRelease.Task.ConfigureAwait(false);
            return new RecorderFinalizationResult(
                AbortIsFinalized,
                "contract.partial.wav",
                AbortIsFinalized ? null : reason);
        }

        public async Task<RecorderFinalizationResult?> ShutdownAsync(
            AudioAttemptLease? activeLease,
            TimeSpan deadline,
            CancellationToken cancellationToken = default)
        {
            Interlocked.Increment(ref ShutdownCalls);
            ShutdownEntered.TrySetResult(true);
            if (BlockShutdown) await _shutdownRelease.Task.ConfigureAwait(false);
            if (ShutdownWaitsForAbortProof && Volatile.Read(ref AbortCalls) > 0)
                await _abortProofRelease.Task.ConfigureAwait(false);
            return activeLease == null
                ? null
                : new RecorderFinalizationResult(true, "contract.partial.wav", null);
        }

        public void ReleaseShutdown() => _shutdownRelease.TrySetResult(true);
        public void ReleaseAbortProof() => _abortProofRelease.TrySetResult(true);

        public void RaiseUnexpected(AudioAttemptLease lease, string message) =>
            _captureTerminated?.Invoke(this, new RecorderCaptureFailedEventArgs(lease, message));
    }

    private sealed class FakePipeline : ITranscriptionPipeline
    {
        public bool BlockCaptureSnapshot { get; set; }
        public bool BlockOnCheckpoint { get; set; }
        public bool BlockAfterRaw { get; set; }
        public bool BlockSynchronouslyBeforeTask { get; set; }
        public int AbandonCalls;
        private readonly ManualResetEventSlim _captureSnapshotRelease = new();
        private readonly TaskCompletionSource<bool> _afterRawRelease =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        private readonly ManualResetEventSlim _synchronousSetupRelease = new();
        public TaskCompletionSource<bool> AfterRawEntered { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource<bool> AbandonObserved { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public ManualResetEventSlim CaptureSnapshotEntered { get; } = new();
        public ManualResetEventSlim SynchronousSetupEntered { get; } = new();

        public void ReleaseCaptureSnapshot() => _captureSnapshotRelease.Set();
        public void ReleaseAfterRaw() => _afterRawRelease.TrySetResult(true);
        public void ReleaseSynchronousSetup() => _synchronousSetupRelease.Set();

        public TranscriptionAttemptSnapshot CaptureAttemptSnapshot(string? providerOverride = null)
        {
            if (BlockCaptureSnapshot)
            {
                CaptureSnapshotEntered.Set();
                _captureSnapshotRelease.Wait();
            }
            return TranscriptionAttemptSnapshotFactory.Capture(
                providerOverride ?? "local",
                new[] { "en" },
                new[] { "English" },
                new[] { "WhisperMate" },
                Array.Empty<TextReplacementSnapshot>(),
                Array.Empty<TextReplacementSnapshot>(),
                null,
                cleanupEnabled: true);
        }

        public async Task<TranscriptionResult> TranscribeAsync(
            string audioFilePath,
            TranscriptionAttemptSnapshot snapshot,
            Func<string, int, CancellationToken, Task<bool>> persistCheckpoint,
            Func<string, CancellationToken, Task<bool>> persistRawResult,
            CancellationToken cancellationToken)
        {
            if (BlockSynchronouslyBeforeTask)
            {
                SynchronousSetupEntered.Set();
                _synchronousSetupRelease.Wait();
            }
            var checkpoint = await persistCheckpoint("complete raw transcript", 1, cancellationToken);
            if (!checkpoint) return TranscriptionResult.Failure("checkpoint rejected");
            if (BlockOnCheckpoint)
                return TranscriptionResult.Failure("blocked checkpoint unexpectedly returned");
            var raw = await persistRawResult("complete raw transcript", cancellationToken);
            if (raw && BlockAfterRaw)
            {
                AfterRawEntered.TrySetResult(true);
                await _afterRawRelease.Task.ConfigureAwait(false);
                return TranscriptionResult.Success("late cleaned transcript");
            }
            return raw
                ? TranscriptionResult.Success("complete raw transcript")
                : TranscriptionResult.Failure("raw result rejected");
        }

        public void AbandonLocalRecognition(TranscriptionAttemptSnapshot snapshot)
        {
            Interlocked.Increment(ref AbandonCalls);
            AbandonObserved.TrySetResult(true);
        }
    }

    private sealed class FakeHistory : IRecordingHistory
    {
        private readonly object _lock = new();
        private readonly Dictionary<Guid, AIDictation.Models.Recording> _rows = new();
        private readonly HistoryTombstoneFence _tombstoneFence = new();
        private readonly TaskCompletionSource<bool> _upsertRelease =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public bool BlockUpsert { get; set; }
        public AIDictation.Models.TranscriptionStatus? BlockUpsertStatus { get; set; }
        public bool RejectUpsert { get; set; }
        public AIDictation.Models.TranscriptionStatus? RejectUpsertStatus { get; set; }
        public TaskCompletionSource<bool> UpsertEntered { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource<bool> BlockedUpsertEntered { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public TaskCompletionSource<bool> BlockedUpsertFinished { get; } =
            new(TaskCreationOptions.RunContinuationsAsynchronously);
        public int BatchTombstoneCalls;
        public IReadOnlyCollection<Guid> LastBatchTombstoneIds { get; private set; } =
            Array.Empty<Guid>();
        public bool PersistenceHealthy => true;

        public void ReleaseUpsert() => _upsertRelease.TrySetResult(true);

        public AIDictation.Models.Recording? Get(Guid id)
        {
            lock (_lock) return _rows.TryGetValue(id, out var row) ? Clone(row) : null;
        }

        public IReadOnlyList<AIDictation.Models.Recording> GetAll()
        {
            lock (_lock) return _rows.Values.Select(Clone).ToArray();
        }

        public Task<bool> UpdateAsync(
            AIDictation.Models.Recording recording,
            CancellationToken cancellationToken = default) =>
            UpsertAsync(recording, cancellationToken);

        public async Task<bool> UpsertAsync(
            AIDictation.Models.Recording recording,
            CancellationToken cancellationToken = default)
        {
            UpsertEntered.TrySetResult(true);
            var wasBlocked = false;
            if (BlockUpsert &&
                (BlockUpsertStatus == null || BlockUpsertStatus == recording.Status))
            {
                wasBlocked = true;
                BlockedUpsertEntered.TrySetResult(true);
                await _upsertRelease.Task.ConfigureAwait(false);
            }
            try
            {
                if (RejectUpsert &&
                    (RejectUpsertStatus == null || RejectUpsertStatus == recording.Status))
                    return false;
                if (!_tombstoneFence.CanPublish(recording.Id)) return false;
                lock (_lock)
                {
                    if (_rows.TryGetValue(recording.Id, out var existing) &&
                        existing.Revision > recording.Revision)
                        return true;
                    _rows[recording.Id] = Clone(recording);
                }
                return true;
            }
            finally
            {
                if (wasBlocked) BlockedUpsertFinished.TrySetResult(true);
            }
        }

        public Task<bool> RemoveMetadataAfterTombstoneAsync(
            Guid id,
            CancellationToken cancellationToken = default)
        {
            return RemoveMetadataAfterTombstonesAsync(new[] { id }, cancellationToken);
        }

        public Task<bool> RemoveMetadataAfterTombstonesAsync(
            IReadOnlyCollection<Guid> ids,
            CancellationToken cancellationToken = default)
        {
            Interlocked.Increment(ref BatchTombstoneCalls);
            LastBatchTombstoneIds = ids.ToArray();
            lock (_lock)
            {
                foreach (var id in ids) _rows.Remove(id);
            }
            _tombstoneFence.Commit(ids);
            return Task.FromResult(true);
        }

        public Task<bool> ClearMetadataAfterTombstoneAsync(
            CancellationToken cancellationToken = default)
        {
            Guid[] ids;
            lock (_lock)
            {
                ids = _rows.Keys.ToArray();
                _rows.Clear();
            }
            _tombstoneFence.Commit(ids);
            return Task.FromResult(true);
        }

        private static AIDictation.Models.Recording Clone(AIDictation.Models.Recording row) => new()
        {
            Id = row.Id,
            Timestamp = row.Timestamp,
            AudioFilePath = row.AudioFilePath,
            Transcription = row.Transcription,
            RawTranscription = row.RawTranscription,
            CheckpointTranscription = row.CheckpointTranscription,
            Status = row.Status,
            ErrorMessage = row.ErrorMessage,
            RetryCount = row.RetryCount,
            SourceIntegrity = row.SourceIntegrity,
            Revision = row.Revision,
            Duration = row.Duration,
            WordCount = row.WordCount
        };
    }

    private sealed class FakeUsageReporter : ICompletedTranscriptionUsageReporter
    {
        public int Calls;
        public string? LastText;
        public bool ReportedAfterTerminalRelease;
        public Func<bool>? IsTerminalAndReleased { get; set; }

        public void Report(string text)
        {
            LastText = text;
            ReportedAfterTerminalRelease = IsTerminalAndReleased?.Invoke() == true;
            Interlocked.Increment(ref Calls);
        }
    }

    private sealed class FakeAppState : IAudioAppState
    {
        private readonly object _lock = new();
        private readonly ManualResetEventSlim _startPreparingRelease = new();
        private readonly ManualResetEventSlim _startRetryingRelease = new();
        private string _current = "Idle";
        public bool BlockStartPreparing { get; set; }
        public bool BlockStartRetrying { get; set; }
        public bool RejectRecordingBecameReady { get; set; }
        public Action? StartPreparingPublished { get; set; }
        public Action? RecordingReadyPublished { get; set; }
        public ManualResetEventSlim StartPreparingEntered { get; } = new();
        public ManualResetEventSlim StartRetryingEntered { get; } = new();
        public string Current { get { lock (_lock) return _current; } }
        private bool Move(string state) { lock (_lock) _current = state; return true; }
        public void ReleaseStartPreparing() => _startPreparingRelease.Set();
        public void ReleaseStartRetrying() => _startRetryingRelease.Set();
        public bool StartPreparing(bool isCommandMode = false)
        {
            if (BlockStartPreparing)
            {
                StartPreparingEntered.Set();
                _startPreparingRelease.Wait();
            }
            var moved = Move("Preparing");
            StartPreparingPublished?.Invoke();
            return moved;
        }
        public bool RecordingBecameReady()
        {
            if (RejectRecordingBecameReady) return false;
            var moved = Move("Recording");
            RecordingReadyPublished?.Invoke();
            return moved;
        }
        public bool StartFinalizing() => Move("Finalizing");
        public bool StartProcessing() => Move("Processing");
        public bool StartRetrying()
        {
            if (BlockStartRetrying)
            {
                StartRetryingEntered.Set();
                _startRetryingRelease.Wait();
            }
            return Move("Retrying");
        }
        public bool SetResult(string text) => Move("Result");
        public bool SetError(string message) => Move("Error");
        public void Reset() => Move("Idle");
    }

    private sealed class DelegateHandler : HttpMessageHandler
    {
        private readonly Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> _send;
        public DelegateHandler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send) =>
            _send = send;
        protected override Task<HttpResponseMessage> SendAsync(
            HttpRequestMessage request,
            CancellationToken cancellationToken) => _send(request, cancellationToken);
    }

    private sealed class DisposableResource : IDisposable
    {
        public int Generation { get; }
        public bool Disposed { get; private set; }
        public DisposableResource(int generation) => Generation = generation;
        public void Dispose() => Disposed = true;
    }

    private sealed class RepeatingReadStream : Stream
    {
        private long _remaining;

        public RepeatingReadStream(long length) => _remaining = length;

        public override bool CanRead => true;
        public override bool CanSeek => false;
        public override bool CanWrite => false;
        public override long Length => throw new NotSupportedException();
        public override long Position
        {
            get => throw new NotSupportedException();
            set => throw new NotSupportedException();
        }

        public override int Read(byte[] buffer, int offset, int count)
        {
            var read = (int)Math.Min(count, _remaining);
            if (read == 0) return 0;
            Array.Fill(buffer, (byte)'a', offset, read);
            _remaining -= read;
            return read;
        }

        public override ValueTask<int> ReadAsync(
            Memory<byte> buffer,
            CancellationToken cancellationToken = default)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var read = (int)Math.Min(buffer.Length, _remaining);
            if (read == 0) return ValueTask.FromResult(0);
            buffer.Span[..read].Fill((byte)'a');
            _remaining -= read;
            return ValueTask.FromResult(read);
        }

        public override void Flush() { }
        public override long Seek(long offset, SeekOrigin origin) =>
            throw new NotSupportedException();
        public override void SetLength(long value) =>
            throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) =>
            throw new NotSupportedException();
    }

    private sealed class DisconnectingContent : HttpContent
    {
        protected override Task SerializeToStreamAsync(Stream stream, TransportContext? context) =>
            Task.FromException(new IOException("response body disconnected"));

        protected override bool TryComputeLength(out long length)
        {
            length = 10;
            return true;
        }
    }

    private sealed class BlockingContent : HttpContent
    {
        private readonly TaskCompletionSource<bool> _release =
            new(TaskCreationOptions.RunContinuationsAsynchronously);

        public void Release() => _release.TrySetResult(true);

        protected override async Task SerializeToStreamAsync(Stream stream, TransportContext? context)
        {
            await _release.Task.ConfigureAwait(false);
            await stream.WriteAsync(new byte[10]).ConfigureAwait(false);
        }

        protected override bool TryComputeLength(out long length)
        {
            length = 10;
            return true;
        }
    }
}
