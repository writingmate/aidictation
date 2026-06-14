using System;
using System.IO;
using System.Net.Http;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;
using Whisper.net;

namespace AIDictation.Services;

/// <summary>
/// On-device transcription using whisper.cpp via Whisper.net, providing the offline
/// mode that macOS implements with Parakeet. The multilingual ggml model is downloaded
/// once to local app data and reused across sessions.
/// </summary>
public sealed class WhisperLocalService : IDisposable
{
    // MARK: - Singleton

    public static WhisperLocalService Instance { get; } = new();

    // MARK: - Constants

    private static class Constants
    {
        public const string ModelFileName = "ggml-small.bin";
        public const string ModelDownloadUrl =
            "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin";
        public const int WhisperSampleRate = 16000;
        public const int DownloadBufferSize = 81920;
    }

    // MARK: - Public Callbacks

    /// <summary>Reports model download progress from 0.0 to 1.0.</summary>
    public event EventHandler<double>? ModelDownloadProgress;

    // MARK: - Private Properties

    private readonly SemaphoreSlim _modelLock = new(1, 1);
    private readonly object _factoryLock = new();
    private WhisperFactory? _factory;

    // MARK: - Initialization

    private WhisperLocalService() { }

    // MARK: - Public API

    public static string ModelPath
    {
        get
        {
            var appData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
            return Path.Combine(appData, "AIDictation", "models", Constants.ModelFileName);
        }
    }

    public bool IsModelDownloaded => File.Exists(ModelPath);

    /// <summary>
    /// Downloads the whisper model when missing. Safe to call repeatedly.
    /// </summary>
    public async Task EnsureModelAsync(CancellationToken cancellationToken = default)
    {
        if (IsModelDownloaded) return;

        await _modelLock.WaitAsync(cancellationToken);
        try
        {
            if (IsModelDownloaded) return;

            var modelDir = Path.GetDirectoryName(ModelPath)!;
            Directory.CreateDirectory(modelDir);
            var tempPath = ModelPath + ".download";

            // Resume a partial download instead of restarting ~470 MB from zero.
            long existingBytes = File.Exists(tempPath) ? new FileInfo(tempPath).Length : 0;

            using var httpClient = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };

            for (var attempt = 0; ; attempt++)
            {
                using var downloadRequest = new HttpRequestMessage(HttpMethod.Get, Constants.ModelDownloadUrl);
                if (existingBytes > 0)
                {
                    downloadRequest.Headers.Range =
                        new System.Net.Http.Headers.RangeHeaderValue(existingBytes, null);
                }

                using var response = await httpClient.SendAsync(
                    downloadRequest,
                    HttpCompletionOption.ResponseHeadersRead,
                    cancellationToken);

                if (existingBytes > 0)
                {
                    var rejected = response.StatusCode == System.Net.HttpStatusCode.RequestedRangeNotSatisfiable;
                    var totalLength = response.Content.Headers.ContentRange?.Length;
                    var oversized = response.StatusCode == System.Net.HttpStatusCode.PartialContent &&
                                    totalLength.HasValue && existingBytes >= totalLength.Value;

                    if ((rejected || oversized) && attempt == 0)
                    {
                        // The partial file is corrupt or from a different model
                        // version; appending would produce a garbage model.
                        try { File.Delete(tempPath); } catch { }
                        existingBytes = 0;
                        continue;
                    }

                    if (response.StatusCode != System.Net.HttpStatusCode.PartialContent)
                    {
                        // The server ignored the range request; FileMode.Create
                        // below truncates and starts over.
                        existingBytes = 0;
                    }
                }
                response.EnsureSuccessStatusCode();

                var remainingBytes = response.Content.Headers.ContentLength ?? -1L;
                var totalBytes = remainingBytes > 0 ? existingBytes + remainingBytes : -1L;
                long readBytes = existingBytes;

                await using (var contentStream = await response.Content.ReadAsStreamAsync(cancellationToken))
                await using (var fileStream = new FileStream(
                    tempPath,
                    existingBytes > 0 ? FileMode.Append : FileMode.Create,
                    FileAccess.Write))
                {
                    var buffer = new byte[Constants.DownloadBufferSize];
                    int read;
                    while ((read = await contentStream.ReadAsync(buffer, cancellationToken)) > 0)
                    {
                        await fileStream.WriteAsync(buffer.AsMemory(0, read), cancellationToken);
                        readBytes += read;
                        if (totalBytes > 0)
                        {
                            ModelDownloadProgress?.Invoke(this, (double)readBytes / totalBytes);
                        }
                    }
                }
                break;
            }

            File.Move(tempPath, ModelPath, overwrite: true);

            // A factory created from an earlier model file must not survive the swap.
            lock (_factoryLock)
            {
                _factory?.Dispose();
                _factory = null;
            }

            ModelDownloadProgress?.Invoke(this, 1.0);
        }
        finally
        {
            // On failure the partial .download file is kept so the next attempt resumes.
            _modelLock.Release();
        }
    }

    /// <summary>
    /// Transcribes a WAV file fully on-device. Downloads the model on first use.
    /// </summary>
    /// <param name="audioFilePath">Path to the recorded WAV file (any sample rate).</param>
    /// <param name="languageCode">Whisper language code, or "auto" for detection.</param>
    public async Task<string> TranscribeAsync(
        string audioFilePath,
        string languageCode = "auto",
        CancellationToken cancellationToken = default)
    {
        await EnsureModelAsync(cancellationToken);

        var factory = GetFactory();
        var whisperLanguage = NormalizeLanguage(languageCode);

        var resampledPath = Path.Combine(
            Path.GetTempPath(),
            $"aidictation_whisper_{Guid.NewGuid():N}.wav");

        try
        {
            ResampleToWhisperFormat(audioFilePath, resampledPath);

            using var processor = factory.CreateBuilder()
                .WithLanguage(whisperLanguage)
                .Build();

            var text = new StringBuilder();
            await using var fileStream = File.OpenRead(resampledPath);
            await foreach (var segment in processor.ProcessAsync(fileStream, cancellationToken))
            {
                text.Append(segment.Text);
            }

            return text.ToString().Trim();
        }
        finally
        {
            try { File.Delete(resampledPath); } catch { }
        }
    }

    public void Dispose()
    {
        _factory?.Dispose();
        _factory = null;
        _modelLock.Dispose();
    }

    // MARK: - Private Methods

    private WhisperFactory GetFactory()
    {
        // EnsureModelAsync disposes the factory after a model swap; without the
        // lock a concurrent transcription could grab a disposed instance.
        lock (_factoryLock)
        {
            _factory ??= WhisperFactory.FromPath(ModelPath);
            return _factory;
        }
    }

    private static void ResampleToWhisperFormat(string inputPath, string outputPath)
    {
        using var reader = new AudioFileReader(inputPath);
        ISampleProvider provider = reader;

        if (provider.WaveFormat.Channels > 1)
        {
            provider = provider.ToMono();
        }

        if (provider.WaveFormat.SampleRate != Constants.WhisperSampleRate)
        {
            provider = new WdlResamplingSampleProvider(provider, Constants.WhisperSampleRate);
        }

        WaveFileWriter.CreateWaveFile16(outputPath, provider);
    }

    private static string NormalizeLanguage(string languageCode)
    {
        if (string.IsNullOrWhiteSpace(languageCode) || languageCode == "auto")
        {
            return "auto";
        }

        // Whisper expects bare ISO 639-1 codes ("en-GB" -> "en"); unsupported
        // regional codes fall back to auto-detection.
        var bareCode = languageCode.Split('-')[0].ToLowerInvariant();
        return bareCode.Length == 2 ? bareCode : "auto";
    }
}
