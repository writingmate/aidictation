using System;
using System.IO;
using System.Text;

namespace AIDictation.Services;

public sealed record AudioValidationResult(bool IsValid, string? ErrorMessage, long DataBytes = 0);

public static class AudioContainerValidator
{
    public static AudioValidationResult ValidateFinalizedWave(string path)
    {
        const string genericError =
            "The recording did not finish saving correctly. The recoverable source was kept.";

        try
        {
            using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
            using var reader = new BinaryReader(stream, Encoding.ASCII, leaveOpen: true);
            if (stream.Length < 44 || ReadFourCc(reader) != "RIFF")
                return new AudioValidationResult(false, genericError);

            var riffSize = reader.ReadUInt32();
            if (ReadFourCc(reader) != "WAVE" || riffSize + 8L != stream.Length)
                return new AudioValidationResult(false, genericError);

            var sawFormat = false;
            var sawData = false;
            ushort blockAlignment = 0;
            long dataBytes = 0;
            while (stream.Position + 8 <= stream.Length)
            {
                var chunkId = ReadFourCc(reader);
                var chunkSize = reader.ReadUInt32();
                var chunkEnd = stream.Position + chunkSize;
                if (chunkEnd > stream.Length)
                    return new AudioValidationResult(false, genericError);

                if (chunkId == "fmt ")
                {
                    if (sawFormat || chunkSize < 16)
                        return new AudioValidationResult(false, genericError);
                    var formatTag = reader.ReadUInt16();
                    var channels = reader.ReadUInt16();
                    var sampleRate = reader.ReadUInt32();
                    var byteRate = reader.ReadUInt32();
                    var blockAlign = reader.ReadUInt16();
                    var bitsPerSample = reader.ReadUInt16();
                    var bytesPerSample = (bitsPerSample + 7u) / 8u;
                    var expectedBlockAlignment = (ulong)channels * bytesPerSample;
                    var expectedByteRate = (ulong)sampleRate * blockAlign;
                    sawFormat = channels > 0 && sampleRate > 0 && blockAlign > 0 &&
                                bitsPerSample > 0 && formatTag is 1 or 3 or 0xFFFE &&
                                (formatTag != 0xFFFE || chunkSize >= 40) &&
                                expectedBlockAlignment == blockAlign && expectedByteRate == byteRate;
                    if (!sawFormat) return new AudioValidationResult(false, genericError);
                    blockAlignment = blockAlign;
                }
                else if (chunkId == "data")
                {
                    if (!sawFormat || sawData || chunkSize == 0 || chunkSize % blockAlignment != 0)
                        return new AudioValidationResult(false, genericError);
                    sawData = true;
                    dataBytes += chunkSize;
                }

                var paddedEnd = chunkEnd + (chunkSize % 2);
                if (paddedEnd > stream.Length)
                    return new AudioValidationResult(false, genericError);
                stream.Position = paddedEnd;
            }

            return stream.Position == stream.Length && sawFormat && sawData && dataBytes > 0 &&
                   blockAlignment > 0 && dataBytes % blockAlignment == 0
                ? new AudioValidationResult(true, null, dataBytes)
                : new AudioValidationResult(false, genericError);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or EndOfStreamException)
        {
            return new AudioValidationResult(false, genericError);
        }
    }

    private static string ReadFourCc(BinaryReader reader) =>
        Encoding.ASCII.GetString(reader.ReadBytes(4));
}
