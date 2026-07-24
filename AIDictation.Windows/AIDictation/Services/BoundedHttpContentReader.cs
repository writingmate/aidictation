using System;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace AIDictation.Services;

public class InvalidHttpResponseBodyException : Exception
{
    public InvalidHttpResponseBodyException(string message, Exception? inner = null) :
        base(message, inner) { }
}

public sealed class HttpResponseBodyTooLargeException : InvalidHttpResponseBodyException
{
    public HttpResponseBodyTooLargeException(int maximumBytes) :
        base($"The response exceeded the {maximumBytes}-byte limit.")
    {
        MaximumBytes = maximumBytes;
    }

    public int MaximumBytes { get; }
}

/// <summary>
/// Reads HTTP response content with a hard byte cap. Four MiB is comfortably
/// above the largest supported cleanup completion and allows hundreds of
/// thousands of transcript words, while preventing an unbounded response from
/// consuming process memory.
/// </summary>
public static class BoundedHttpContentReader
{
    public const int MaxResponseBytes = 4 * 1024 * 1024;
    private const int BufferBytes = 64 * 1024;

    public static Task<string> ReadAsStringAsync(
        HttpContent content,
        CancellationToken cancellationToken) =>
        ReadAsStringAsync(content, MaxResponseBytes, cancellationToken);

    public static async Task<string> ReadAsStringAsync(
        HttpContent content,
        int maximumBytes,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(content);
        if (maximumBytes <= 0)
            throw new ArgumentOutOfRangeException(nameof(maximumBytes));

        cancellationToken.ThrowIfCancellationRequested();
        if (content.Headers.ContentLength is { } declaredLength &&
            declaredLength > maximumBytes)
        {
            throw new HttpResponseBodyTooLargeException(maximumBytes);
        }

        var streamTask = content.ReadAsStreamAsync(cancellationToken);
        Stream stream;
        try
        {
            stream = await streamTask.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            DisposeLateStream(streamTask);
            throw;
        }
        using (stream)
        {
            return await ReadStreamAsStringAsync(
                    content,
                    stream,
                    maximumBytes,
                    cancellationToken)
                .ConfigureAwait(false);
        }
    }

    private static async Task<string> ReadStreamAsStringAsync(
        HttpContent content,
        Stream stream,
        int maximumBytes,
        CancellationToken cancellationToken)
    {
        var initialCapacity = content.Headers.ContentLength is { } contentLength
            ? (int)Math.Min(contentLength, maximumBytes)
            : 0;
        using var bytes = new MemoryStream(initialCapacity);
        // Keep this buffer attempt-owned. A transport is allowed to ignore
        // cancellation and complete ReadAsync late, so returning pooled memory
        // here could let that late read corrupt another request's buffer.
        var buffer = new byte[Math.Min(BufferBytes, maximumBytes)];
        while (true)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var remainingWithSentinel = (int)Math.Min(
                buffer.Length,
                maximumBytes - bytes.Length + 1);
            var readTask = stream.ReadAsync(
                    buffer.AsMemory(0, remainingWithSentinel),
                    cancellationToken)
                .AsTask();
            var count = await WaitAsync(readTask, cancellationToken).ConfigureAwait(false);
            if (count == 0) break;
            if (bytes.Length > maximumBytes - count)
                throw new HttpResponseBodyTooLargeException(maximumBytes);
            bytes.Write(buffer, 0, count);
        }

        cancellationToken.ThrowIfCancellationRequested();
        try
        {
            var byteCount = checked((int)bytes.Length);
            var bufferContents = bytes.GetBuffer();
            var (encoding, preambleBytes) = ResolveEncoding(
                content,
                bufferContents.AsSpan(0, byteCount));
            var text = encoding.GetString(
                bufferContents,
                preambleBytes,
                byteCount - preambleBytes);
            cancellationToken.ThrowIfCancellationRequested();
            return text;
        }
        catch (Exception ex) when (
            ex is ArgumentException or DecoderFallbackException or NotSupportedException)
        {
            throw new InvalidHttpResponseBodyException(
                "The response body did not contain valid text.",
                ex);
        }
    }

    private static (Encoding Encoding, int PreambleBytes) ResolveEncoding(
        HttpContent content,
        ReadOnlySpan<byte> bytes)
    {
        // BOMs override a declared charset, but every selected decoder remains
        // strict so malformed complete bodies cannot silently acquire U+FFFD.
        if (bytes.StartsWith(new byte[] { 0x00, 0x00, 0xFE, 0xFF }))
            return (new UTF32Encoding(true, true, true), 4);
        if (bytes.StartsWith(new byte[] { 0xFF, 0xFE, 0x00, 0x00 }))
            return (new UTF32Encoding(false, true, true), 4);
        if (bytes.StartsWith(new byte[] { 0xEF, 0xBB, 0xBF }))
            return (new UTF8Encoding(false, true), 3);
        if (bytes.StartsWith(new byte[] { 0xFE, 0xFF }))
            return (new UnicodeEncoding(true, true, true), 2);
        if (bytes.StartsWith(new byte[] { 0xFF, 0xFE }))
            return (new UnicodeEncoding(false, true, true), 2);

        var charset = content.Headers.ContentType?.CharSet?.Trim().Trim('"');
        if (string.IsNullOrWhiteSpace(charset))
        {
            return (
                new UTF8Encoding(
                    encoderShouldEmitUTF8Identifier: false,
                    throwOnInvalidBytes: true),
                0);
        }

        return (
            Encoding.GetEncoding(
                charset,
                EncoderFallback.ExceptionFallback,
                DecoderFallback.ExceptionFallback),
            0);
    }

    private static async Task<T> WaitAsync<T>(
        Task<T> task,
        CancellationToken cancellationToken)
    {
        try
        {
            return await task.WaitAsync(cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            ObserveLateTask(task);
            throw;
        }
    }

    private static void ObserveLateTask(Task task)
    {
        _ = task.ContinueWith(
            completed => _ = completed.Exception,
            CancellationToken.None,
            TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }

    private static void DisposeLateStream(Task<Stream> task)
    {
        _ = task.ContinueWith(
            completed =>
            {
                if (completed.Status == TaskStatus.RanToCompletion)
                    completed.Result.Dispose();
                else
                    _ = completed.Exception;
            },
            CancellationToken.None,
            TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }
}
