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
using Newtonsoft.Json.Linq;

namespace AIDictation.Services;

/// <summary>
/// Transcribes recordings via the WritingMate cloud backend (with server-side LLM
/// post-processing) or fully on-device via Whisper, mirroring the macOS/Android pipeline:
/// vocabulary prompt, language hints, context rules from the foreground app, then local
/// dictionary replacements and shortcut expansions.
/// </summary>
public sealed class TranscriptionService
{
    // MARK: - Singleton

    public static TranscriptionService Instance { get; } = new();

    // MARK: - Constants

    private static class Constants
    {
        public const int MaxRetryAttempts = 3;
        public const int RetryDelayMs = 1000;
        public const int HttpTimeoutSeconds = 120;
        public const long MaxUploadBytes = 24L * 1024 * 1024;
    }

    // MARK: - Private Properties

    private readonly HttpClient _httpClient;
    private readonly SettingsService _settings;

    // MARK: - Initialization

    private TranscriptionService()
    {
        _httpClient = new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(Constants.HttpTimeoutSeconds)
        };
        _settings = SettingsService.Instance;
    }

    // MARK: - Public API

    /// <summary>
    /// Transcribes an audio file using the configured provider (cloud, on-device, or auto),
    /// optionally forced to a specific provider (used by history re-transcription).
    /// </summary>
    public async Task<TranscriptionResult> TranscribeAsync(
        string audioFilePath,
        CancellationToken cancellationToken = default,
        string? providerOverride = null)
    {
        if (!File.Exists(audioFilePath))
        {
            return TranscriptionResult.Failure("Audio file not found");
        }

        // Capture the foreground app before any await so context rules match the
        // window the user dictated into, not this app.
        var contextInstructions = GetActiveContextInstructions();

        var useOffline = ResolveProvider(providerOverride) == AppSettings.LocalTranscriptionProvider;

        string? rawText = null;
        Exception? lastException = null;

        for (int attempt = 0; attempt < Constants.MaxRetryAttempts; attempt++)
        {
            try
            {
                rawText = useOffline
                    ? await TranscribeOfflineAsync(audioFilePath, contextInstructions, cancellationToken)
                    : await TranscribeWithCloudAsync(audioFilePath, contextInstructions, cancellationToken);

                if (rawText != null) break;
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception ex)
            {
                lastException = ex;

                // A cloud failure in auto mode falls back to the on-device
                // model when it is already downloaded.
                if (!useOffline && IsAutoProvider(providerOverride) &&
                    WhisperLocalService.Instance.IsModelDownloaded)
                {
                    useOffline = true;
                    continue;
                }

                // Client errors (bad key, quota, payload) and configuration
                // problems will not succeed on retry.
                if (IsNonRetryable(ex))
                    break;

                if (attempt < Constants.MaxRetryAttempts - 1)
                {
                    await Task.Delay(Constants.RetryDelayMs * (attempt + 1), cancellationToken);
                }
            }
        }

        if (string.IsNullOrWhiteSpace(rawText))
        {
            return TranscriptionResult.Failure(
                lastException?.Message ?? "Transcription failed after multiple attempts");
        }

        var processedText = ApplyDictionaryReplacements(rawText);
        processedText = ApplyShortcutExpansions(processedText);

        ReportWordUsage(processedText);

        return TranscriptionResult.Success(processedText, rawText);
    }

    /// <summary>
    /// Checks whether the active transcription mode is ready to use.
    /// </summary>
    public bool IsConfigured =>
        IsOfflineMode || !string.IsNullOrEmpty(BuildConfig.TranscriptionApiKey);

    public bool IsOfflineMode =>
        ResolveProvider(null) == AppSettings.LocalTranscriptionProvider;

    /// <summary>
    /// Resolves the effective provider: "auto" uses cloud when the network is
    /// available and falls back to on-device otherwise.
    /// </summary>
    private string ResolveProvider(string? overrideProvider)
    {
        var provider = overrideProvider ?? _settings.Settings.TranscriptionProvider;

        if (provider == AppSettings.AutoTranscriptionProvider)
        {
            // An adapter being up does not guarantee internet, and the local
            // model may never have been downloaded; prefer whichever side can
            // actually do the work right now.
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

    private bool IsAutoProvider(string? overrideProvider) =>
        (overrideProvider ?? _settings.Settings.TranscriptionProvider) == AppSettings.AutoTranscriptionProvider;

    private static bool IsNonRetryable(Exception ex) =>
        ex is InvalidOperationException ||
        (ex is HttpRequestException { StatusCode: { } status } && (int)status is >= 400 and < 500);

    // MARK: - Cloud Pipeline

    private async Task<string?> TranscribeWithCloudAsync(
        string audioFilePath,
        string? contextInstructions,
        CancellationToken cancellationToken)
    {
        var apiKey = BuildConfig.TranscriptionApiKey;
        if (string.IsNullOrEmpty(apiKey))
        {
            throw new InvalidOperationException("Transcription service is not configured in this build");
        }

        var audioFile = new FileInfo(audioFilePath);
        if (audioFile.Length > Constants.MaxUploadBytes)
        {
            throw new InvalidOperationException(
                "Recording is too large for the transcription service. Try shorter dictations.");
        }

        var languageCodes = GetSelectedLanguageCodes();
        var languageNames = GetSelectedLanguageNames(languageCodes);
        var apiLanguage = languageCodes.Count == 1 && languageCodes[0] != "auto"
            ? languageCodes[0].Split('-')[0]
            : null;

        var transcriptionPrompt = BuildLanguageAwarePrompt(BuildVocabularyPrompt(), languageNames);
        var postProcessingEnabled = _settings.Settings.EnableLLMPostProcessing;
        var postProcessingPrompt = postProcessingEnabled
            ? JoinNonEmpty("\n", transcriptionPrompt, contextInstructions)
            : null;

        // The backend's FormData parser rejects .NET's default multipart framing
        // (quoted boundary, unquoted disposition names, filename* parameter,
        // charset on text parts); emit curl-style framing instead.
        var boundary = Guid.NewGuid().ToString("N");
        using var content = new MultipartFormDataContent(boundary);
        content.Headers.Remove("Content-Type");
        content.Headers.TryAddWithoutValidation("Content-Type", $"multipart/form-data; boundary={boundary}");

        await using var fileStream = File.OpenRead(audioFilePath);
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

        if (!string.IsNullOrEmpty(transcriptionPrompt))
        {
            content.Add(CreateFormField("prompt", transcriptionPrompt));
            content.Add(CreateFormField("stt_prompt", transcriptionPrompt));
        }

        if (!string.IsNullOrEmpty(postProcessingPrompt))
        {
            content.Add(CreateFormField("post_processing_prompt", postProcessingPrompt));
        }

        if (!postProcessingEnabled)
        {
            content.Add(CreateFormField("post_processing", "false"));
        }

        if (!string.IsNullOrEmpty(apiLanguage))
        {
            content.Add(CreateFormField("language", apiLanguage));
        }

        using var request = new HttpRequestMessage(HttpMethod.Post, BuildConfig.TranscriptionEndpoint)
        {
            Content = content
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);

        var response = await _httpClient.SendAsync(request, cancellationToken);
        var body = await response.Content.ReadAsStringAsync(cancellationToken);

        if (!response.IsSuccessStatusCode)
        {
            throw new HttpRequestException(
                $"Transcription failed ({(int)response.StatusCode}): {Truncate(body, 200)}",
                null,
                response.StatusCode);
        }

        return ParseTranscriptionText(body);
    }

    // MARK: - Offline Pipeline

    private async Task<string?> TranscribeOfflineAsync(
        string audioFilePath,
        string? contextInstructions,
        CancellationToken cancellationToken)
    {
        if (!WhisperLocalService.Instance.IsModelDownloaded)
        {
            // Kicking off a ~470 MB download (with retries) in the middle of a
            // dictation is never what the user wants; fail fast instead.
            throw new InvalidOperationException(
                "The on-device model is not downloaded yet. Open Settings to download it.");
        }

        var languageCodes = GetSelectedLanguageCodes();
        var whisperLanguage = languageCodes.Count == 1 ? languageCodes[0] : "auto";

        var rawText = await WhisperLocalService.Instance.TranscribeAsync(
            audioFilePath, whisperLanguage, cancellationToken);

        if (string.IsNullOrWhiteSpace(rawText)) return rawText;

        if (_settings.Settings.EnableLLMPostProcessing)
        {
            var languageNames = GetSelectedLanguageNames(languageCodes);
            rawText = await LanguagePostProcessService.Instance.PostProcessAsync(
                rawText,
                languageNames.Count > 0 ? languageNames : new List<string> { "auto" },
                contextInstructions,
                cancellationToken);
        }

        return rawText;
    }

    // MARK: - Prompt Building

    private string? BuildVocabularyPrompt()
    {
        var vocabulary = _settings.DictionaryEntries
            .Where(e => e.IsEnabled && !string.IsNullOrWhiteSpace(e.Trigger))
            .Select(e => string.IsNullOrWhiteSpace(e.Replacement) ? e.Trigger : e.Replacement!)
            .ToList();

        var phrases = _settings.Shortcuts
            .Where(s => s.IsEnabled && !string.IsNullOrWhiteSpace(s.VoiceTrigger))
            .Select(s => s.VoiceTrigger)
            .ToList();

        var parts = new List<string>();
        if (vocabulary.Count > 0) parts.Add($"Vocabulary: {string.Join(", ", vocabulary)}");
        if (phrases.Count > 0) parts.Add($"Phrases: {string.Join(", ", phrases)}");

        return parts.Count > 0 ? string.Join(". ", parts) : null;
    }

    private static string? BuildLanguageAwarePrompt(string? prompt, IReadOnlyList<string> languageNames)
    {
        string? languageHint = null;
        if (languageNames.Count > 1)
        {
            languageHint =
                $"The speaker will use one of these selected languages: {string.Join(", ", languageNames)}. " +
                "Detect the spoken language from the audio and transcribe it in that same language.";
        }

        return JoinNonEmpty("\n", languageHint, prompt);
    }

    private string? GetActiveContextInstructions()
    {
        var enabledRules = _settings.ContextRules.Where(r => r.IsEnabled).ToList();
        if (enabledRules.Count == 0) return null;

        var foregroundApp = ForegroundWindowHelper.GetForegroundApp();

        var instructions = enabledRules
            .Where(rule => RuleMatches(rule, foregroundApp))
            .Select(r => r.Instructions)
            .Where(i => !string.IsNullOrWhiteSpace(i))
            .ToList();

        return instructions.Count > 0 ? string.Join("\n", instructions) : null;
    }

    private static bool RuleMatches(ContextRule rule, ForegroundWindowHelper.ForegroundApp? app)
    {
        var hasProcessFilter = rule.ProcessNames.Any(p => !string.IsNullOrWhiteSpace(p));
        var hasTitleFilter = rule.TitlePatterns.Any(p => !string.IsNullOrWhiteSpace(p));

        // Rules without filters apply everywhere.
        if (!hasProcessFilter && !hasTitleFilter) return true;
        if (app == null) return false;

        if (hasProcessFilter && rule.ProcessNames.Any(p =>
                !string.IsNullOrWhiteSpace(p) &&
                app.Value.ProcessName.Contains(p.Trim(), StringComparison.OrdinalIgnoreCase)))
        {
            return true;
        }

        if (hasTitleFilter && rule.TitlePatterns.Any(p =>
                !string.IsNullOrWhiteSpace(p) &&
                app.Value.WindowTitle.Contains(p.Trim(), StringComparison.OrdinalIgnoreCase)))
        {
            return true;
        }

        return false;
    }

    // MARK: - Local Text Expansion

    private string ApplyDictionaryReplacements(string text)
    {
        var entries = _settings.DictionaryEntries
            .Where(e => e.IsEnabled && !string.IsNullOrEmpty(e.Trigger))
            .OrderByDescending(e => e.Trigger.Length); // Longer matches first

        foreach (var entry in entries)
        {
            if (!string.IsNullOrEmpty(entry.Replacement))
            {
                var pattern = $@"\b{Regex.Escape(entry.Trigger)}\b";
                var replacement = entry.Replacement;
                // MatchEvaluator keeps user text literal ($1, $& etc. must not
                // be interpreted as group references).
                text = Regex.Replace(text, pattern, _ => replacement, RegexOptions.IgnoreCase);
            }
        }

        return text;
    }

    private string ApplyShortcutExpansions(string text)
    {
        var shortcuts = _settings.Shortcuts
            .Where(s => s.IsEnabled && !string.IsNullOrEmpty(s.VoiceTrigger))
            .OrderByDescending(s => s.VoiceTrigger.Length); // Longer matches first

        foreach (var shortcut in shortcuts)
        {
            var pattern = $@"\b{Regex.Escape(shortcut.VoiceTrigger)}\b";
            var expansion = shortcut.Expansion;
            text = Regex.Replace(text, pattern, _ => expansion, RegexOptions.IgnoreCase);
        }

        return text;
    }

    // MARK: - Helper Methods

    /// <summary>
    /// Builds a text form field with curl-style framing: quoted disposition
    /// name and no Content-Type header, which strict FormData parsers expect.
    /// </summary>
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

    private List<string> GetSelectedLanguageCodes()
    {
        var languages = _settings.Settings.SelectedLanguages;
        if (languages == null || languages.Count == 0)
        {
            return new List<string> { "auto" };
        }

        var codes = languages
            .Where(c => !string.IsNullOrWhiteSpace(c))
            .Distinct()
            .ToList();

        // "auto" combined with explicit languages means auto-detect.
        if (codes.Count != 1 && codes.Contains("auto"))
        {
            codes.Remove("auto");
        }

        return codes.Count > 0 ? codes : new List<string> { "auto" };
    }

    private static List<string> GetSelectedLanguageNames(IEnumerable<string> codes)
    {
        return codes
            .Where(c => c != "auto")
            .Select(LanguageExtensions.FromCode)
            .Where(l => l.HasValue)
            .Select(l => l!.Value.GetDisplayName())
            .ToList();
    }

    private static string? ParseTranscriptionText(string body)
    {
        if (string.IsNullOrWhiteSpace(body)) return null;

        var trimmed = body.Trim();
        if (trimmed.StartsWith('{'))
        {
            try
            {
                var json = JObject.Parse(trimmed);
                return json["text"]?.ToString()
                       ?? json["transcript"]?.ToString()
                       ?? json["transcription"]?.ToString()
                       ?? trimmed;
            }
            catch
            {
                return trimmed;
            }
        }

        return trimmed;
    }

    private static void ReportWordUsage(string text)
    {
        var words = text.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length;
        if (words > 0 && AuthService.Instance.IsAuthenticated)
        {
            _ = AuthService.Instance.UpdateWordCountAsync(words);
        }
    }

    private static string? JoinNonEmpty(string separator, params string?[] parts)
    {
        var nonEmpty = parts.Where(p => !string.IsNullOrWhiteSpace(p)).ToList();
        return nonEmpty.Count > 0 ? string.Join(separator, nonEmpty) : null;
    }

    private static string Truncate(string value, int maxLength)
    {
        return value.Length <= maxLength ? value : value[..maxLength];
    }
}

/// <summary>
/// Result of a transcription operation.
/// </summary>
public class TranscriptionResult
{
    public bool IsSuccess { get; private set; }
    public string? Text { get; private set; }
    public string? RawText { get; private set; }
    public string? ErrorMessage { get; private set; }

    private TranscriptionResult() { }

    public static TranscriptionResult Success(string text, string? rawText = null)
    {
        return new TranscriptionResult
        {
            IsSuccess = true,
            Text = text,
            RawText = rawText ?? text
        };
    }

    public static TranscriptionResult Failure(string errorMessage)
    {
        return new TranscriptionResult
        {
            IsSuccess = false,
            ErrorMessage = errorMessage
        };
    }
}
