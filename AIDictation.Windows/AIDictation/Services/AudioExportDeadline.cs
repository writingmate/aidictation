using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace AIDictation.Services;

public static class AudioExportDeadline
{
    public static async Task<T> RunAsync<T>(
        Func<CancellationToken, T> export,
        TimeSpan deadlineDuration,
        CancellationToken cancellationToken,
        Action? detachedCompletion = null)
    {
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        deadline.CancelAfter(deadlineDuration);
        var deadlineToken = deadline.Token;
        var exportTask = Task.Run(() => export(deadlineToken), CancellationToken.None);
        try
        {
            return await exportTask.WaitAsync(deadlineToken).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            ObserveDetachedTask(exportTask, detachedCompletion);
            throw;
        }
        catch (OperationCanceledException ex)
        {
            ObserveDetachedTask(exportTask, detachedCompletion);
            throw new TimeoutException(
                "Preparing the audio upload took too long. The original recording was kept.",
                ex);
        }
    }

    private static void ObserveDetachedTask(Task task, Action? detachedCompletion)
    {
        _ = task.ContinueWith(
            completed =>
            {
                if (completed.IsFaulted) _ = completed.Exception;
                if (detachedCompletion == null) return;
                try { detachedCompletion(); }
                catch { }
            },
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }
}

public sealed record CloudLeafTranscriptionResult(
    string Text,
    bool RequiresGenericCleanup);

public static class CloudGenericCleanupPolicy
{
    public static async Task<string> ApplyAsync(
        CloudLeafTranscriptionResult recognition,
        bool cleanupEnabled,
        Func<string, CancellationToken, Task<string>> cleanup,
        CancellationToken cancellationToken)
    {
        if (!cleanupEnabled || !recognition.RequiresGenericCleanup)
            return recognition.Text;

        try
        {
            var cleaned = await cleanup(recognition.Text, cancellationToken).ConfigureAwait(false);
            cancellationToken.ThrowIfCancellationRequested();
            return string.IsNullOrWhiteSpace(cleaned) ? recognition.Text : cleaned;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch
        {
            return recognition.Text;
        }
    }
}

/// <summary>
/// Runs a cloud upload tree in source order. A single root may use the
/// provider's one-stage cleanup. Initial bulk leaves and every descendant of a
/// rejected 413 upload are always raw recognition, so cleanup can run exactly
/// once over the complete merged transcript.
/// </summary>
public sealed class CloudAudioLeafProcessor<TLeaf>
{
    public const int DefaultMaxSplitDepth = 8;

    private readonly int _maxSplitDepth;

    public CloudAudioLeafProcessor(int maxSplitDepth = DefaultMaxSplitDepth)
    {
        _maxSplitDepth = maxSplitDepth;
    }

    public async Task<CloudLeafTranscriptionResult> ProcessAsync(
        IReadOnlyList<TLeaf> initialLeaves,
        Func<TLeaf, bool, CancellationToken, Task<string>> upload,
        Func<TLeaf, CancellationToken, Task<IReadOnlyList<TLeaf>>> split,
        Func<string, int, CancellationToken, Task<bool>> persistCheckpoint,
        CancellationToken cancellationToken)
    {
        var orderedText = new List<string>();
        var completed = 0;
        var requiresGenericCleanup = initialLeaves.Count != 1;

        async Task ProcessLeafAsync(TLeaf leaf, int depth, bool allowOneStageCleanup)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                var text = (await upload(leaf, allowOneStageCleanup, cancellationToken)
                        .ConfigureAwait(false))
                    .Trim();
                if (string.IsNullOrWhiteSpace(text))
                    throw new InvalidAudioResponseException(
                        "The transcription service returned no text for part of the recording.");

                orderedText.Add(text);
                completed++;
                var merged = string.Join(" ", orderedText);
                if (!await persistCheckpoint(merged, completed, cancellationToken).ConfigureAwait(false))
                    throw new AudioStoreException(
                        "The transcription checkpoint could not be saved. Processing stopped before later audio was sent.");
            }
            catch (AudioPayloadTooLargeException) when (depth < _maxSplitDepth)
            {
                requiresGenericCleanup = true;
                var children = await split(leaf, cancellationToken).ConfigureAwait(false);
                if (children.Count < 2)
                    throw new AudioPayloadTooLargeException(
                        "This audio part is too large and cannot be split safely.");
                foreach (var child in children)
                    await ProcessLeafAsync(child, depth + 1, allowOneStageCleanup: false)
                        .ConfigureAwait(false);
            }
        }

        for (var index = 0; index < initialLeaves.Count; index++)
        {
            var allowOneStageCleanup = initialLeaves.Count == 1 && index == 0;
            await ProcessLeafAsync(initialLeaves[index], 0, allowOneStageCleanup)
                .ConfigureAwait(false);
        }

        return new CloudLeafTranscriptionResult(
            string.Join(" ", orderedText),
            requiresGenericCleanup);
    }
}
