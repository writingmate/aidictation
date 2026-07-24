using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Threading;
using System.Threading.Tasks;

namespace AIDictation.Services;

public class AudioRequestException : Exception
{
    public HttpStatusCode? StatusCode { get; }
    public bool IsRetryable { get; }

    public AudioRequestException(
        string message,
        HttpStatusCode? statusCode = null,
        bool isRetryable = false,
        Exception? inner = null) : base(message, inner)
    {
        StatusCode = statusCode;
        IsRetryable = isRetryable;
    }
}

public sealed class AudioPayloadTooLargeException : AudioRequestException
{
    public AudioPayloadTooLargeException(string message) :
        base(message, HttpStatusCode.RequestEntityTooLarge, isRetryable: false) { }
}

public sealed class InvalidAudioResponseException : AudioRequestException
{
    public InvalidAudioResponseException(string message, Exception? inner = null) :
        base(message, null, isRetryable: false, inner) { }
}

public sealed record AudioHttpResponse(
    HttpStatusCode StatusCode,
    string? MediaType,
    string Body,
    int AttemptCount);

/// <summary>
/// Shared typed request policy for a single upload leaf. A fresh request must be
/// created for every attempt because multipart streams are single-use.
/// </summary>
public sealed class AudioHttpRecoveryPolicy
{
    public const int MaxAttempts = 3;
    public static readonly TimeSpan MaxRetryDelay = TimeSpan.FromSeconds(10);

    private readonly Func<TimeSpan, CancellationToken, Task> _delay;

    public AudioHttpRecoveryPolicy(Func<TimeSpan, CancellationToken, Task>? delay = null)
    {
        _delay = delay ?? Task.Delay;
    }

    public async Task<AudioHttpResponse> ExecuteAsync(
        Func<CancellationToken, Task<HttpResponseMessage>> sendAttempt,
        TimeSpan requestDeadline,
        CancellationToken cancellationToken)
    {
        Exception? lastError = null;
        for (var attempt = 1; attempt <= MaxAttempts; attempt++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            deadline.CancelAfter(requestDeadline);
            HttpResponseMessage? response = null;
            try
            {
                var sendTask = Task.Run(
                    () => sendAttempt(deadline.Token),
                    CancellationToken.None);
                try
                {
                    response = await sendTask.WaitAsync(deadline.Token).ConfigureAwait(false);
                }
                catch
                {
                    DisposeLateResponse(sendTask);
                    throw;
                }
                var mediaType = response.Content.Headers.ContentType?.MediaType;
                var status = response.StatusCode;
                if (status == HttpStatusCode.RequestEntityTooLarge)
                    throw new AudioPayloadTooLargeException("The server rejected this audio part as too large.");

                // Every non-success is classified from headers. Diagnostic bodies
                // are optional and may stall forever; never drain them before a
                // permanent failure, a Retry-After decision, or a 413 split.
                if (status != HttpStatusCode.OK)
                {
                    var retryable = IsRetryableStatus(status);
                    var error = new AudioRequestException(
                        UserMessage(status, string.Empty),
                        status,
                        retryable);
                    if (!retryable || attempt == MaxAttempts)
                        throw error;

                    var retryDelay = RetryDelay(response, attempt);
                    lastError = error;
                    await _delay(retryDelay, cancellationToken).ConfigureAwait(false);
                    continue;
                }

                // Only a complete 200 body is a transcription result. A timeout
                // or disconnect while draining it is transient for this leaf.
                string body;
                try
                {
                    body = await BoundedHttpContentReader.ReadAsStringAsync(
                            response.Content,
                            deadline.Token)
                        .ConfigureAwait(false);
                }
                catch (InvalidHttpResponseBodyException ex)
                {
                    // A complete 200 with an oversized or undecodable body is a
                    // malformed response, not a transport failure. Never replay
                    // the upload automatically.
                    throw new InvalidAudioResponseException(
                        "The transcription service returned an invalid response. The recording was kept.",
                        ex);
                }
                return new AudioHttpResponse(status, mediaType, body, attempt);
            }
            catch (AudioPayloadTooLargeException)
            {
                throw;
            }
            catch (AudioRequestException ex) when (!ex.IsRetryable || attempt == MaxAttempts)
            {
                throw;
            }
            catch (AudioRequestException ex)
            {
                lastError = ex;
                await _delay(DefaultDelay(attempt), cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                throw;
            }
            catch (HttpRequestException ex) when (ex.StatusCode == HttpStatusCode.RequestEntityTooLarge)
            {
                throw new AudioPayloadTooLargeException("The server rejected this audio part as too large.");
            }
            catch (HttpRequestException ex) when (ex.StatusCode is { } status && !IsRetryableStatus(status))
            {
                throw new AudioRequestException(UserMessage(status, string.Empty), status, false, ex);
            }
            catch (Exception ex) when (IsTransientTransport(ex))
            {
                lastError = ex;
                if (attempt == MaxAttempts)
                {
                    throw new AudioRequestException(
                        "The transcription connection failed after three attempts. Retry from History.",
                        null,
                        isRetryable: true,
                        ex);
                }
                await _delay(DefaultDelay(attempt), cancellationToken).ConfigureAwait(false);
            }
            finally
            {
                response?.RequestMessage?.Dispose();
                response?.Dispose();
            }
        }

        throw new AudioRequestException(
            "The transcription request failed after three attempts.",
            null,
            isRetryable: true,
            lastError);
    }

    public static bool IsRetryableStatus(HttpStatusCode statusCode)
    {
        var value = (int)statusCode;
        return statusCode is HttpStatusCode.RequestTimeout or (HttpStatusCode)429 ||
               value is >= 500 and <= 599;
    }

    public static bool IsPermanentClientStatus(HttpStatusCode statusCode) =>
        (int)statusCode is >= 400 and <= 499 &&
        statusCode is not HttpStatusCode.RequestTimeout and
        not HttpStatusCode.RequestEntityTooLarge and
        not (HttpStatusCode)429;

    private static bool IsTransientTransport(Exception exception) =>
        exception is HttpRequestException or IOException or TimeoutException or OperationCanceledException;

    private static void DisposeLateResponse(Task<HttpResponseMessage> task)
    {
        _ = task.ContinueWith(
            completed =>
            {
                if (completed.Status == TaskStatus.RanToCompletion)
                {
                    completed.Result.RequestMessage?.Dispose();
                    completed.Result.Dispose();
                }
                else
                {
                    _ = completed.Exception;
                }
            },
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }

    private static TimeSpan RetryDelay(HttpResponseMessage response, int attempt)
    {
        var retryAfter = response.Headers.RetryAfter;
        if (retryAfter?.Delta is { } delta)
            return ClampDelay(delta);
        if (retryAfter?.Date is { } date)
            return ClampDelay(date - DateTimeOffset.UtcNow);

        if (response.Headers.TryGetValues("Retry-After", out var values))
        {
            var value = values.FirstOrDefault();
            if (double.TryParse(value, NumberStyles.Number, CultureInfo.InvariantCulture, out var seconds))
                return ClampDelay(TimeSpan.FromSeconds(seconds));
        }
        return DefaultDelay(attempt);
    }

    private static TimeSpan DefaultDelay(int attempt) =>
        TimeSpan.FromSeconds(Math.Min(attempt, 2));

    private static TimeSpan ClampDelay(TimeSpan value)
    {
        if (value < TimeSpan.Zero) return TimeSpan.Zero;
        return value > MaxRetryDelay ? MaxRetryDelay : value;
    }

    private static string UserMessage(HttpStatusCode status, string body)
    {
        return status switch
        {
            HttpStatusCode.BadRequest or HttpStatusCode.UnprocessableEntity =>
                "The transcription service could not process this recording. Retry it or record a shorter clip.",
            HttpStatusCode.Conflict =>
                "The transcription request conflicted with the current service state. Retry from History.",
            HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden =>
                "Cloud transcription is not authorized. Check your account or switch to offline mode.",
            HttpStatusCode.NotFound =>
                "The cloud transcription service is unavailable in this build.",
            (HttpStatusCode)429 =>
                "The transcription service is busy. Retry from History in a moment.",
            _ when (int)status >= 500 =>
                "The transcription service is temporarily unavailable. Retry from History.",
            _ => $"Transcription failed ({(int)status})."
        };
    }
}

/// <summary>
/// Runs upload leaves strictly in order. Only a 413-rejected leaf is split;
/// completed siblings are never replayed.
/// </summary>
public sealed class SequentialAudioLeafProcessor<TLeaf>
{
    public const int DefaultMaxSplitDepth = 8;

    private readonly int _maxSplitDepth;

    public SequentialAudioLeafProcessor(int maxSplitDepth = DefaultMaxSplitDepth)
    {
        _maxSplitDepth = maxSplitDepth;
    }

    public async Task<string> ProcessAsync(
        IReadOnlyList<TLeaf> initialLeaves,
        Func<TLeaf, CancellationToken, Task<string>> upload,
        Func<TLeaf, CancellationToken, Task<IReadOnlyList<TLeaf>>> split,
        Func<string, int, CancellationToken, Task<bool>> persistCheckpoint,
        CancellationToken cancellationToken)
    {
        var orderedText = new List<string>();
        var completed = 0;

        async Task ProcessLeafAsync(TLeaf leaf, int depth)
        {
            cancellationToken.ThrowIfCancellationRequested();
            try
            {
                var text = (await upload(leaf, cancellationToken).ConfigureAwait(false)).Trim();
                if (string.IsNullOrWhiteSpace(text))
                    throw new InvalidAudioResponseException("The transcription service returned no text for part of the recording.");

                orderedText.Add(text);
                completed++;
                var merged = string.Join(" ", orderedText);
                if (!await persistCheckpoint(merged, completed, cancellationToken).ConfigureAwait(false))
                    throw new AudioStoreException("The transcription checkpoint could not be saved. Processing stopped before later audio was sent.");
            }
            catch (AudioPayloadTooLargeException) when (depth < _maxSplitDepth)
            {
                var children = await split(leaf, cancellationToken).ConfigureAwait(false);
                if (children.Count < 2)
                    throw new AudioPayloadTooLargeException("This audio part is too large and cannot be split safely.");
                foreach (var child in children)
                    await ProcessLeafAsync(child, depth + 1).ConfigureAwait(false);
            }
        }

        foreach (var leaf in initialLeaves)
            await ProcessLeafAsync(leaf, 0).ConfigureAwait(false);

        return string.Join(" ", orderedText);
    }
}
