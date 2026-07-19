using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using AIDictation.Helpers;
using AIDictation.Models;

namespace AIDictation.Services;

/// <summary>
/// Bounded recognition pipeline. All attempt inputs are immutable, cloud
/// leaves are sequential/checkpointed, and optional cleanup can never discard
/// complete raw recognition.
/// </summary>
public sealed class TranscriptionService : ITranscriptionPipeline
{
    private static class Constants
    {
        public static readonly TimeSpan CloudLeafDeadline = TimeSpan.FromSeconds(45);
        public const long MaxUploadBytes = 24L * 1024 * 1024;
    }

    private readonly HttpClient _httpClient;
    private readonly SettingsService _settings;
    private readonly AudioHttpRecoveryPolicy _requestPolicy;

    public static TranscriptionService Instance { get; } = new();

    private TranscriptionService()
    {
        _httpClient = new HttpClient { Timeout = Timeout.InfiniteTimeSpan };
        _settings = SettingsService.Instance;
        _requestPolicy = new AudioHttpRecoveryPolicy();
    }

    public bool IsConfigured =>
        IsOfflineMode || !string.IsNullOrEmpty(BuildConfig.TranscriptionApiKey);

    public bool IsOfflineMode =>
        ResolveProvider(null) == AppSettings.LocalTranscriptionProvider;

    public void AbandonLocalRecognition(TranscriptionAttemptSnapshot snapshot)
    {
        if (snapshot.Provider == AppSettings.LocalTranscriptionProvider)
            WhisperLocalService.Instance.ResetAfterAbandonedAttempt();
    }

    /// <summary>
    /// Must be called before the first await in the recording workflow.
    /// </summary>
    public TranscriptionAttemptSnapshot CaptureAttemptSnapshot(string? providerOverride = null)
    {
        var contextInstructions = GetActiveContextInstructions();
        var languageCodes = GetSelectedLanguageCodes();
        var languageNames = GetSelectedLanguageNames(languageCodes);
        var dictionaryEntries = _settings.DictionaryEntries
            .Where(entry => entry.IsEnabled && !string.IsNullOrWhiteSpace(entry.Trigger))
            .ToArray();
        var vocabulary = dictionaryEntries
            .Select(entry => entry.Trigger.Trim())
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        var replacements = dictionaryEntries
            .Where(entry => !string.IsNullOrWhiteSpace(entry.Replacement))
            .Select(entry => new TextReplacementSnapshot(entry.Trigger, entry.Replacement!))
            .OrderByDescending(entry => entry.Trigger.Length)
            .ToArray();
        var expansions = _settings.Shortcuts
            .Where(shortcut => shortcut.IsEnabled && !string.IsNullOrWhiteSpace(shortcut.VoiceTrigger))
            .Select(shortcut => new TextReplacementSnapshot(shortcut.VoiceTrigger, shortcut.Expansion))
            .OrderByDescending(entry => entry.Trigger.Length)
            .ToArray();
        return TranscriptionAttemptSnapshotFactory.Capture(
            ResolveProvider(providerOverride),
            languageCodes,
            languageNames,
            vocabulary,
            replacements,
            expansions,
            contextInstructions,
            _settings.Settings.EnableLLMPostProcessing);
    }

    public Task<TranscriptionResult> TranscribeAsync(
        string audioFilePath,
        CancellationToken cancellationToken = default,
        string? providerOverride = null)
    {
        var snapshot = CaptureAttemptSnapshot(providerOverride);
        return TranscribeAsync(
            audioFilePath,
            snapshot,
            (_, _, _) => Task.FromResult(true),
            (_, _) => Task.FromResult(true),
            cancellationToken);
    }

    public async Task<TranscriptionResult> TranscribeAsync(
        string audioFilePath,
        TranscriptionAttemptSnapshot snapshot,
        Func<string, int, CancellationToken, Task<bool>> persistCheckpoint,
        Func<string, CancellationToken, Task<bool>> persistRawResult,
        CancellationToken cancellationToken)
    {
        if (!File.Exists(audioFilePath))
            return TranscriptionResult.Failure("The saved audio file could not be found.");

        try
        {
            string rawText;
            CloudLeafTranscriptionResult? cloudResult = null;
            if (snapshot.Provider == AppSettings.LocalTranscriptionProvider)
            {
                rawText = await TranscribeOfflineAsync(audioFilePath, snapshot, cancellationToken)
                    .ConfigureAwait(false);
                if (string.IsNullOrWhiteSpace(rawText))
                    return TranscriptionResult.Failure("No speech was detected in this recording.");
                if (!await persistCheckpoint(rawText, 1, cancellationToken).ConfigureAwait(false))
                    return TranscriptionResult.Failure("The transcription checkpoint could not be saved.");
            }
            else
            {
                cloudResult = await TranscribeWithCloudAsync(
                        audioFilePath,
                        snapshot,
                        persistCheckpoint,
                        cancellationToken)
                    .ConfigureAwait(false);
                rawText = cloudResult.Text;
            }

            if (string.IsNullOrWhiteSpace(rawText))
                return TranscriptionResult.Failure("No speech was detected in this recording.");
            if (!await persistRawResult(rawText, cancellationToken).ConfigureAwait(false))
                return TranscriptionResult.Failure("The recognized text could not be saved.");

            var processedText = rawText;
            if (snapshot.Provider == AppSettings.LocalTranscriptionProvider && snapshot.CleanupEnabled)
            {
                // This service owns its own cleanup deadline and returns raw text
                // for timeout, HTTP failure, invalid JSON, or empty output.
                processedText = await LanguagePostProcessService.Instance.PostProcessAsync(
                        rawText,
                        GetCleanupLanguageDescriptor(snapshot.LanguageCodes),
                        snapshot,
                        cancellationToken)
                    .ConfigureAwait(false);
                if (string.IsNullOrWhiteSpace(processedText)) processedText = rawText;
            }
            else if (cloudResult != null)
            {
                processedText = await CloudGenericCleanupPolicy.ApplyAsync(
                        cloudResult,
                        snapshot.CleanupEnabled,
                        (completeRawText, token) => LanguagePostProcessService.Instance.PostProcessAsync(
                            completeRawText,
                            GetCleanupLanguageDescriptor(snapshot.LanguageCodes),
                            snapshot,
                            token),
                        cancellationToken)
                    .ConfigureAwait(false);
            }

            processedText = ApplyLiteralReplacements(processedText, snapshot.Replacements);
            processedText = ApplyLiteralReplacements(processedText, snapshot.Expansions);
            if (string.IsNullOrWhiteSpace(processedText)) processedText = rawText;

            // A native recognizer or HTTP stack may finish after the owning
            // deadline. Do not return a deliverable result for an attempt that
            // has already been abandoned.
            cancellationToken.ThrowIfCancellationRequested();
            return TranscriptionResult.Success(processedText, rawText);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (AudioRequestException ex)
        {
            return TranscriptionResult.Failure(ex.Message);
        }
        catch (AudioStoreException ex)
        {
            return TranscriptionResult.Failure(ex.Message);
        }
        catch (TimeoutException ex)
        {
            return TranscriptionResult.Failure(ex.Message);
        }
        catch (Exception ex)
        {
            return TranscriptionResult.Failure(
                string.IsNullOrWhiteSpace(ex.Message)
                    ? "Transcription failed. Retry from History."
                    : ex.Message);
        }
    }

    private async Task<CloudLeafTranscriptionResult> TranscribeWithCloudAsync(
        string audioFilePath,
        TranscriptionAttemptSnapshot snapshot,
        Func<string, int, CancellationToken, Task<bool>> persistCheckpoint,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrEmpty(BuildConfig.TranscriptionApiKey))
            throw new InvalidOperationException("Cloud mode is not configured in this build.");

        var temporaryDirectory = Path.Combine(
            Path.GetTempPath(),
            $"aidictation-upload-{Guid.NewGuid():N}");
        try
        {
            var initialLeaves = await WaveChunkExporter.CreateInitialLeavesAsync(
                    audioFilePath,
                    temporaryDirectory,
                    Constants.MaxUploadBytes,
                    cancellationToken)
                .ConfigureAwait(false);
            var processor = new CloudAudioLeafProcessor<AudioUploadLeaf>();
            return await processor.ProcessAsync(
                    initialLeaves,
                    (leaf, allowOneStageCleanup, token) => UploadCloudLeafAsync(
                        leaf.Path,
                        snapshot,
                        allowOneStageCleanup,
                        token),
                    (leaf, token) => WaveChunkExporter.SplitRejectedLeafAsync(leaf, temporaryDirectory, token),
                    persistCheckpoint,
                    cancellationToken)
                .ConfigureAwait(false);
        }
        finally
        {
            WaveChunkExporter.DeleteTemporaryWorkspace(temporaryDirectory);
        }
    }

    private async Task<string> UploadCloudLeafAsync(
        string audioFilePath,
        TranscriptionAttemptSnapshot snapshot,
        bool allowOneStageCleanup,
        CancellationToken cancellationToken)
    {
        var response = await _requestPolicy.ExecuteAsync(
                token => SendCloudAttemptAsync(
                    audioFilePath,
                    snapshot,
                    allowOneStageCleanup,
                    token),
                Constants.CloudLeafDeadline,
                cancellationToken)
            .ConfigureAwait(false);
        return AudioTranscriptionResponseParser.ParseCompleteText(response.Body, response.MediaType);
    }

    private async Task<HttpResponseMessage> SendCloudAttemptAsync(
        string audioFilePath,
        TranscriptionAttemptSnapshot snapshot,
        bool allowOneStageCleanup,
        CancellationToken cancellationToken)
    {
        var boundary = Guid.NewGuid().ToString("N");
        var content = new MultipartFormDataContent(boundary);
        content.Headers.Remove("Content-Type");
        content.Headers.TryAddWithoutValidation("Content-Type", $"multipart/form-data; boundary={boundary}");

        FileStream fileStream;
        try
        {
            fileStream = new FileStream(
                audioFilePath,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                128 * 1024,
                FileOptions.Asynchronous | FileOptions.SequentialScan);
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw new AudioRequestException(
                "The saved recording could not be read. Check storage access and retry from History.",
                null,
                isRetryable: false,
                ex);
        }
        var fileContent = new StreamContent(fileStream);
        fileContent.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");
        fileContent.Headers.ContentDisposition = new ContentDispositionHeaderValue("form-data")
        {
            Name = "\"file\"",
            FileName = $"\"{Path.GetFileName(audioFilePath)}\""
        };
        content.Add(fileContent);
        content.Add(CreateFormField("model", BuildConfig.TranscriptionModel));
        content.Add(CreateFormField("temperature", "0"));
        content.Add(CreateFormField("response_format", "text"));
        if (!string.IsNullOrWhiteSpace(snapshot.RecognitionPrompt))
        {
            content.Add(CreateFormField("prompt", snapshot.RecognitionPrompt));
            content.Add(CreateFormField("stt_prompt", snapshot.RecognitionPrompt));
        }
        if (allowOneStageCleanup && !string.IsNullOrWhiteSpace(snapshot.PostProcessingPrompt))
            content.Add(CreateFormField("post_processing_prompt", snapshot.PostProcessingPrompt));
        if (!allowOneStageCleanup || !snapshot.CleanupEnabled)
            content.Add(CreateFormField("post_processing", "false"));

        var language = snapshot.LanguageCodes.Count == 1 && snapshot.LanguageCodes[0] != "auto"
            ? snapshot.LanguageCodes[0].Split('-')[0]
            : null;
        if (!string.IsNullOrWhiteSpace(language))
            content.Add(CreateFormField("language", language));

        var request = new HttpRequestMessage(HttpMethod.Post, BuildConfig.TranscriptionEndpoint)
        {
            Content = content
        };
        request.Headers.Authorization = new AuthenticationHeaderValue(
            "Bearer",
            BuildConfig.TranscriptionApiKey);
        try
        {
            var response = await _httpClient.SendAsync(
                    request,
                    HttpCompletionOption.ResponseHeadersRead,
                    cancellationToken)
                .ConfigureAwait(false);
            response.RequestMessage ??= request;
            return response;
        }
        catch
        {
            request.Dispose();
            throw;
        }
    }

    private async Task<string> TranscribeOfflineAsync(
        string audioFilePath,
        TranscriptionAttemptSnapshot snapshot,
        CancellationToken cancellationToken)
    {
        if (!WhisperLocalService.Instance.IsModelDownloaded)
            throw new InvalidOperationException(
                "The offline speech model is not downloaded. Open Settings to download it.");

        var whisperLanguage = snapshot.LanguageCodes.Count == 1
            ? snapshot.LanguageCodes[0]
            : "auto";
        return await WhisperLocalService.Instance.TranscribeAsync(
                audioFilePath,
                whisperLanguage,
                cancellationToken)
            .ConfigureAwait(false);
    }

    private string ResolveProvider(string? overrideProvider)
    {
        var provider = overrideProvider ?? _settings.Settings.TranscriptionProvider;
        if (provider == AppSettings.AutoTranscriptionProvider)
        {
            var cloudConfigured = !string.IsNullOrEmpty(BuildConfig.TranscriptionApiKey);
            var online = System.Net.NetworkInformation.NetworkInterface.GetIsNetworkAvailable();
            if (online && cloudConfigured) return AppSettings.CloudTranscriptionProvider;
            if (WhisperLocalService.Instance.IsModelDownloaded) return AppSettings.LocalTranscriptionProvider;
            return cloudConfigured
                ? AppSettings.CloudTranscriptionProvider
                : AppSettings.LocalTranscriptionProvider;
        }
        return provider == AppSettings.LocalTranscriptionProvider
            ? AppSettings.LocalTranscriptionProvider
            : AppSettings.CloudTranscriptionProvider;
    }

    private string? GetActiveContextInstructions()
    {
        var enabledRules = _settings.ContextRules.Where(rule => rule.IsEnabled).ToList();
        if (enabledRules.Count == 0) return null;
        var foregroundApp = ForegroundWindowHelper.GetForegroundApp();
        var instructions = enabledRules
            .Where(rule => RuleMatches(rule, foregroundApp))
            .Select(rule => rule.Instructions)
            .Where(instruction => !string.IsNullOrWhiteSpace(instruction))
            .ToList();
        return instructions.Count > 0 ? string.Join("\n", instructions) : null;
    }

    private static bool RuleMatches(ContextRule rule, ForegroundWindowHelper.ForegroundApp? app)
    {
        var hasProcessFilter = rule.ProcessNames.Any(value => !string.IsNullOrWhiteSpace(value));
        var hasTitleFilter = rule.TitlePatterns.Any(value => !string.IsNullOrWhiteSpace(value));
        if (!hasProcessFilter && !hasTitleFilter) return true;
        if (app == null) return false;
        if (hasProcessFilter && rule.ProcessNames.Any(value =>
                !string.IsNullOrWhiteSpace(value) &&
                app.Value.ProcessName.Contains(value.Trim(), StringComparison.OrdinalIgnoreCase)))
            return true;
        return hasTitleFilter && rule.TitlePatterns.Any(value =>
            !string.IsNullOrWhiteSpace(value) &&
            app.Value.WindowTitle.Contains(value.Trim(), StringComparison.OrdinalIgnoreCase));
    }

    private List<string> GetSelectedLanguageCodes()
    {
        var languages = _settings.Settings.SelectedLanguages;
        if (languages == null || languages.Count == 0) return new List<string> { "auto" };
        var codes = languages.Where(code => !string.IsNullOrWhiteSpace(code)).Distinct().ToList();
        if (codes.Count != 1 && codes.Contains("auto")) codes.Remove("auto");
        return codes.Count > 0 ? codes : new List<string> { "auto" };
    }

    private static List<string> GetSelectedLanguageNames(IEnumerable<string> codes) => codes
        .Where(code => code != "auto")
        .Select(LanguageExtensions.FromCode)
        .Where(language => language.HasValue)
        .Select(language => language!.Value.GetDisplayName())
        .ToList();

    private static IReadOnlyList<string> GetCleanupLanguageDescriptor(IEnumerable<string> codes)
    {
        var names = GetSelectedLanguageNames(codes);
        return names.Count > 0
            ? names
            : new[] { "auto" };
    }

    private static string ApplyLiteralReplacements(
        string text,
        IEnumerable<TextReplacementSnapshot> replacements)
    {
        foreach (var entry in replacements)
        {
            var pattern = $@"\b{Regex.Escape(entry.Trigger)}\b";
            text = Regex.Replace(text, pattern, _ => entry.Replacement, RegexOptions.IgnoreCase);
        }
        return text;
    }

    private static StringContent CreateFormField(string name, string value)
    {
        var field = new StringContent(value);
        field.Headers.ContentType = null;
        field.Headers.ContentDisposition = new ContentDispositionHeaderValue("form-data")
        {
            Name = $"\"{name}\""
        };
        return field;
    }

}
