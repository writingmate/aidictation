using System;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using System.Threading.Tasks;
using NAudio.Wave;

namespace AIDictation.Services;

public sealed record AudioUploadLeaf(string Path, bool IsTemporary);

public static class WaveChunkExporter
{
    public const long MinimumLeafDataBytes = 64 * 1024;
    private static readonly TimeSpan ExportDeadline = TimeSpan.FromSeconds(30);

    public static async Task<IReadOnlyList<AudioUploadLeaf>> CreateInitialLeavesAsync(
        string sourcePath,
        ManagedAudioWorkspace workspace,
        long maximumUploadBytes,
        CancellationToken cancellationToken)
    {
        if (new FileInfo(sourcePath).Length <= maximumUploadBytes)
            return new[] { new AudioUploadLeaf(sourcePath, false) };

        workspace.EnsureOwnedDirectory();
        var safeDataBytes = maximumUploadBytes - (256 * 1024);
        if (safeDataBytes <= MinimumLeafDataBytes)
            throw new InvalidOperationException("The configured upload limit is too small for audio chunks.");

        return await RunExportAsync(
            token => SplitByMaximumData(sourcePath, workspace, safeDataBytes, token),
            workspace,
            cancellationToken).ConfigureAwait(false);
    }

    public static async Task<IReadOnlyList<AudioUploadLeaf>> SplitRejectedLeafAsync(
        AudioUploadLeaf leaf,
        ManagedAudioWorkspace workspace,
        CancellationToken cancellationToken)
    {
        workspace.EnsureOwnedDirectory();
        return await RunExportAsync(
            token => SplitInHalf(leaf.Path, workspace, token),
            workspace,
            cancellationToken).ConfigureAwait(false);
    }

    private static async Task<IReadOnlyList<AudioUploadLeaf>> RunExportAsync(
        Func<CancellationToken, IReadOnlyList<AudioUploadLeaf>> export,
        ManagedAudioWorkspace workspace,
        CancellationToken cancellationToken) =>
        await AudioExportDeadline.RunAsync(
                export,
                ExportDeadline,
                cancellationToken,
                workspace.Dispose)
            .ConfigureAwait(false);

    private static IReadOnlyList<AudioUploadLeaf> SplitByMaximumData(
        string sourcePath,
        ManagedAudioWorkspace workspace,
        long maximumDataBytes,
        CancellationToken cancellationToken)
    {
        using var reader = new WaveFileReader(sourcePath);
        var blockAlign = Math.Max(1, reader.WaveFormat.BlockAlign);
        var alignedMaximum = AlignDown(maximumDataBytes, blockAlign);
        if (alignedMaximum < MinimumLeafDataBytes)
            throw new InvalidOperationException("Audio chunks cannot be made small enough safely.");

        var leaves = new List<AudioUploadLeaf>();
        var remaining = reader.Length;
        while (remaining > 0)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var bytes = Math.Min(remaining, alignedMaximum);
            bytes = AlignDown(bytes, blockAlign);
            if (bytes <= 0) throw new InvalidDataException("Audio contains no complete frames.");
            var path = workspace.FilePath($"leaf-{Guid.NewGuid():N}.wav");
            WriteRange(reader, path, bytes, cancellationToken);
            leaves.Add(new AudioUploadLeaf(path, true));
            remaining -= bytes;
        }
        return leaves;
    }

    private static IReadOnlyList<AudioUploadLeaf> SplitInHalf(
        string sourcePath,
        ManagedAudioWorkspace workspace,
        CancellationToken cancellationToken)
    {
        using var reader = new WaveFileReader(sourcePath);
        var blockAlign = Math.Max(1, reader.WaveFormat.BlockAlign);
        var firstBytes = AlignDown(reader.Length / 2, blockAlign);
        var secondBytes = reader.Length - firstBytes;
        if (firstBytes < MinimumLeafDataBytes || secondBytes < MinimumLeafDataBytes)
            throw new AudioPayloadTooLargeException("This audio part is still too large at the minimum safe split size.");

        var firstPath = workspace.FilePath($"leaf-{Guid.NewGuid():N}.wav");
        var secondPath = workspace.FilePath($"leaf-{Guid.NewGuid():N}.wav");
        WriteRange(reader, firstPath, firstBytes, cancellationToken);
        WriteRange(reader, secondPath, secondBytes, cancellationToken);
        return new[]
        {
            new AudioUploadLeaf(firstPath, true),
            new AudioUploadLeaf(secondPath, true)
        };
    }

    private static void WriteRange(
        WaveFileReader reader,
        string outputPath,
        long bytesToWrite,
        CancellationToken cancellationToken)
    {
        using var writer = new WaveFileWriter(outputPath, reader.WaveFormat);
        var buffer = new byte[128 * 1024];
        var remaining = bytesToWrite;
        while (remaining > 0)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var wanted = (int)Math.Min(buffer.Length, remaining);
            var read = reader.Read(buffer, 0, wanted);
            if (read <= 0) throw new EndOfStreamException("Audio ended before a complete chunk could be exported.");
            writer.Write(buffer, 0, read);
            remaining -= read;
        }
        writer.Flush();
    }

    private static long AlignDown(long value, int alignment) => value - (value % alignment);

}
