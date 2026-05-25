using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Threading.Tasks;
using AIDictation.Helpers;
using AIDictation.Models;
using CredentialManagement;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;

namespace AIDictation.Services;

/// <summary>
/// Handles audio transcription via AIDictation cloud, with legacy provider code retained for compatibility.
/// Supports retry logic, dictionary replacements, shortcut expansion, and optional LLM post-processing.
/// </summary>
public sealed class TranscriptionService
{
    // MARK: - Singleton

    public static TranscriptionService Instance { get; } = new();

    // MARK: - Constants

    private static class Constants
    {
        public const string GroqApiUrl = "https://api.groq.com/openai/v1/audio/transcriptions";
        public const string AIDictationApiUrl = "https://api.aidictation.com/v1/transcribe";
        public const string GroqModel = "whisper-large-v3";
        public const int MaxRetryAttempts = 3;
        public const int RetryDelayMs = 1000;
        public const int HttpTimeoutSeconds = 60;
    }

    private static class CredentialKeys
    {
        public const string GroqApiKey = "AIDictation_Groq_ApiKey";
        public const string CustomApiKey = "AIDictation_Custom_ApiKey";
        public const string CustomApiUrl = "AIDictation_Custom_ApiUrl";
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
    /// Transcribes an audio file using the configured provider.
    /// </summary>
    /// <param name="audioFilePath">Path to the audio file (WAV, MP3, etc.)</param>
    /// <param name="cancellationToken">Cancellation token</param>
    /// <returns>Transcribed and processed text</returns>
    public async Task<TranscriptionResult> TranscribeAsync(
        string audioFilePath,
        CancellationToken cancellationToken = default)
    {
        if (!File.Exists(audioFilePath))
        {
            return TranscriptionResult.Failure("Audio file not found");
        }

        var provider = GetTranscriptionProvider();
        var language = GetPrimaryLanguage();

        // Attempt transcription with retry logic
        string? rawText = null;
        Exception? lastException = null;

        for (int attempt = 0; attempt < Constants.MaxRetryAttempts; attempt++)
        {
            try
            {
                rawText = provider switch
                {
                    "groq" => await TranscribeWithGroqAsync(audioFilePath, language, cancellationToken),
                    "custom" => await TranscribeWithCustomAsync(audioFilePath, language, cancellationToken),
                    "aidictation" => await TranscribeWithAIDictationAsync(audioFilePath, language, cancellationToken),
                    _ => await TranscribeWithAIDictationAsync(audioFilePath, language, cancellationToken)
                };

                if (rawText != null) break;
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (Exception ex)
            {
                lastException = ex;
                if (attempt < Constants.MaxRetryAttempts - 1)
                {
                    await Task.Delay(Constants.RetryDelayMs * (attempt + 1), cancellationToken);
                }
            }
        }

        if (string.IsNullOrEmpty(rawText))
        {
            return TranscriptionResult.Failure(
                lastException?.Message ?? "Transcription failed after multiple attempts");
        }

        // Apply post-processing pipeline
        var processedText = rawText;

        // Apply dictionary replacements
        processedText = ApplyDictionaryReplacements(processedText);

        // Apply shortcut expansions
        processedText = ApplyShortcutExpansions(processedText);

        // Apply LLM post-processing if enabled
        if (_settings.Settings.EnableLLMPostProcessing)
        {
            try
            {
                processedText = await ApplyLLMPostProcessingAsync(processedText, cancellationToken);
            }
            catch
            {
                // Continue with unprocessed text if LLM fails
            }
        }

        return TranscriptionResult.Success(processedText, rawText);
    }

    /// <summary>
    /// Saves API credentials for the specified provider.
    /// </summary>
    public void SaveApiKey(string provider, string apiKey)
    {
        var target = provider switch
        {
            "groq" => CredentialKeys.GroqApiKey,
            "custom" => CredentialKeys.CustomApiKey,
            _ => throw new ArgumentException($"Unknown provider: {provider}")
        };

        SaveCredential(target, apiKey);
    }

    /// <summary>
    /// Saves the custom API endpoint URL.
    /// </summary>
    public void SaveCustomApiUrl(string url)
    {
        SaveCredential(CredentialKeys.CustomApiUrl, url);
    }

    /// <summary>
    /// Gets the API key for the specified provider.
    /// </summary>
    public string? GetApiKey(string provider)
    {
        var target = provider switch
        {
            "groq" => CredentialKeys.GroqApiKey,
            "custom" => CredentialKeys.CustomApiKey,
            _ => null
        };

        return target != null ? LoadCredential(target) : null;
    }

    /// <summary>
    /// Gets the custom API endpoint URL.
    /// </summary>
    public string? GetCustomApiUrl()
    {
        return LoadCredential(CredentialKeys.CustomApiUrl);
    }

    /// <summary>
    /// Checks if the specified provider is configured with valid credentials.
    /// </summary>
    public bool IsProviderConfigured(string provider)
    {
        provider = NormalizeTranscriptionProvider(provider);

        return provider switch
        {
            "groq" => !string.IsNullOrEmpty(GetApiKey("groq")),
            "custom" => !string.IsNullOrEmpty(GetApiKey("custom")) && !string.IsNullOrEmpty(GetCustomApiUrl()),
            "aidictation" => AuthService.Instance.IsAuthenticated,
            _ => false
        };
    }

    // MARK: - Provider Implementations

    private async Task<string?> TranscribeWithGroqAsync(
        string audioFilePath,
        string language,
        CancellationToken cancellationToken)
    {
        var apiKey = GetApiKey("groq");
        if (string.IsNullOrEmpty(apiKey))
        {
            throw new InvalidOperationException("Groq API key not configured");
        }

        using var content = new MultipartFormDataContent();
        await using var fileStream = File.OpenRead(audioFilePath);
        var fileContent = new StreamContent(fileStream);
        fileContent.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");

        content.Add(fileContent, "file", Path.GetFileName(audioFilePath));
        content.Add(new StringContent(Constants.GroqModel), "model");

        if (!string.IsNullOrEmpty(language) && language != "auto")
        {
            content.Add(new StringContent(language), "language");
        }

        using var request = new HttpRequestMessage(HttpMethod.Post, Constants.GroqApiUrl)
        {
            Content = content
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);

        var response = await _httpClient.SendAsync(request, cancellationToken);
        response.EnsureSuccessStatusCode();

        var json = await response.Content.ReadAsStringAsync(cancellationToken);
        var result = JObject.Parse(json);

        return result["text"]?.ToString();
    }

    private async Task<string?> TranscribeWithCustomAsync(
        string audioFilePath,
        string language,
        CancellationToken cancellationToken)
    {
        var apiKey = GetApiKey("custom");
        var apiUrl = GetCustomApiUrl();

        if (string.IsNullOrEmpty(apiUrl))
        {
            throw new InvalidOperationException("Custom API URL not configured");
        }

        using var content = new MultipartFormDataContent();
        await using var fileStream = File.OpenRead(audioFilePath);
        var fileContent = new StreamContent(fileStream);
        fileContent.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");

        content.Add(fileContent, "file", Path.GetFileName(audioFilePath));

        if (!string.IsNullOrEmpty(language) && language != "auto")
        {
            content.Add(new StringContent(language), "language");
        }

        using var request = new HttpRequestMessage(HttpMethod.Post, apiUrl)
        {
            Content = content
        };

        if (!string.IsNullOrEmpty(apiKey))
        {
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);
        }

        var response = await _httpClient.SendAsync(request, cancellationToken);
        response.EnsureSuccessStatusCode();

        var json = await response.Content.ReadAsStringAsync(cancellationToken);
        var result = JObject.Parse(json);

        // Try common response formats
        return result["text"]?.ToString() 
               ?? result["transcript"]?.ToString()
               ?? result["transcription"]?.ToString();
    }

    private async Task<string?> TranscribeWithAIDictationAsync(
        string audioFilePath,
        string language,
        CancellationToken cancellationToken)
    {
        var session = CredentialHelper.LoadSession();
        if (session == null)
        {
            throw new InvalidOperationException("Not authenticated with AIDictation");
        }

        using var content = new MultipartFormDataContent();
        await using var fileStream = File.OpenRead(audioFilePath);
        var fileContent = new StreamContent(fileStream);
        fileContent.Headers.ContentType = new MediaTypeHeaderValue("audio/wav");

        content.Add(fileContent, "file", Path.GetFileName(audioFilePath));

        if (!string.IsNullOrEmpty(language) && language != "auto")
        {
            content.Add(new StringContent(language), "language");
        }

        using var request = new HttpRequestMessage(HttpMethod.Post, Constants.AIDictationApiUrl)
        {
            Content = content
        };
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", session.Value.AccessToken);

        var response = await _httpClient.SendAsync(request, cancellationToken);
        response.EnsureSuccessStatusCode();

        var json = await response.Content.ReadAsStringAsync(cancellationToken);
        var result = JObject.Parse(json);

        return result["text"]?.ToString();
    }

    // MARK: - Post-Processing

    private string ApplyDictionaryReplacements(string text)
    {
        var entries = _settings.DictionaryEntries
            .Where(e => e.IsEnabled && !string.IsNullOrEmpty(e.Trigger))
            .OrderByDescending(e => e.Trigger.Length); // Longer matches first

        foreach (var entry in entries)
        {
            if (entry.Replacement != null)
            {
                // Case-insensitive word boundary replacement
                var pattern = $@"\b{Regex.Escape(entry.Trigger)}\b";
                text = Regex.Replace(text, pattern, entry.Replacement, RegexOptions.IgnoreCase);
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
            // Case-insensitive replacement for voice triggers
            var pattern = $@"\b{Regex.Escape(shortcut.VoiceTrigger)}\b";
            text = Regex.Replace(text, pattern, shortcut.Expansion, RegexOptions.IgnoreCase);
        }

        return text;
    }

    private async Task<string> ApplyLLMPostProcessingAsync(
        string text,
        CancellationToken cancellationToken)
    {
        // Get applicable context rules based on active window
        var contextInstructions = GetActiveContextInstructions();

        var provider = _settings.Settings.PostProcessingProvider;

        // Placeholder for LLM post-processing implementation
        // This would call an LLM API to clean up/format the transcription
        // For now, return the original text
        return text;
    }

    private string GetActiveContextInstructions()
    {
        // Placeholder - would integrate with window detection
        // to find matching context rules
        var applicableRules = _settings.ContextRules
            .Where(r => r.IsEnabled)
            .Select(r => r.Instructions);

        return string.Join("\n", applicableRules);
    }

    // MARK: - Helper Methods

    private string GetPrimaryLanguage()
    {
        var languages = _settings.Settings.SelectedLanguages;
        if (languages == null || languages.Count == 0)
        {
            return "auto";
        }
        return languages[0];
    }

    private string GetTranscriptionProvider()
    {
        var provider = NormalizeTranscriptionProvider(_settings.Settings.TranscriptionProvider);
        if (_settings.Settings.TranscriptionProvider != provider)
        {
            _settings.Settings.TranscriptionProvider = provider;
            _settings.SaveSettings();
        }

        return provider;
    }

    private static string NormalizeTranscriptionProvider(string? _) => AppSettings.CloudTranscriptionProvider;

    private static void SaveCredential(string target, string secret)
    {
        using var credential = new Credential
        {
            Target = target,
            Username = "AIDictation",
            Password = secret,
            PersistanceType = PersistanceType.LocalComputer
        };
        credential.Save();
    }

    private static string? LoadCredential(string target)
    {
        using var credential = new Credential { Target = target };
        if (credential.Load())
        {
            return credential.Password;
        }
        return null;
    }

    private static void DeleteCredential(string target)
    {
        using var credential = new Credential { Target = target };
        credential.Delete();
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
