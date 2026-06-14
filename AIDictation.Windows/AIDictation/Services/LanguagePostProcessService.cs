using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Linq;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using AIDictation.Helpers;
using Newtonsoft.Json.Linq;

namespace AIDictation.Services;

/// <summary>
/// LLM-based cleanup of transcription results for the offline path, ported from the
/// Android LanguagePostProcessClient: corrects obvious speech-to-text errors without
/// translating or rephrasing, and applies context-rule instructions when present.
/// </summary>
public sealed class LanguagePostProcessService
{
    // MARK: - Singleton

    public static LanguagePostProcessService Instance { get; } = new();

    // MARK: - Constants

    private static class Constants
    {
        public const int HttpTimeoutSeconds = 30;
        public const int MinCompletionTokens = 500;
        public const int MaxCompletionTokens = 8000;
    }

    // MARK: - Private Properties

    private readonly HttpClient _httpClient;

    // MARK: - Initialization

    private LanguagePostProcessService()
    {
        _httpClient = new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(Constants.HttpTimeoutSeconds)
        };
    }

    // MARK: - Public API

    /// <summary>
    /// Corrects a raw transcription via the chat completions endpoint.
    /// Returns the original text when the endpoint is unavailable or fails.
    /// </summary>
    /// <param name="rawText">The transcription to clean up.</param>
    /// <param name="languageNames">Display names of the languages the user speaks.</param>
    /// <param name="contextRules">Optional extra instructions from matching context rules.</param>
    public async Task<string> PostProcessAsync(
        string rawText,
        IReadOnlyList<string> languageNames,
        string? contextRules = null,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(rawText)) return rawText;

        var apiKey = BuildConfig.PostProcessingApiKey;
        if (string.IsNullOrEmpty(apiKey))
        {
            Debug.WriteLine("[LanguagePostProcess] API key not configured, skipping");
            return rawText;
        }

        var systemPrompt = BuildSystemPrompt(contextRules);
        var userContent = $"1. [{(languageNames.Count > 0 ? languageNames[0] : "auto")}] {rawText}";

        try
        {
            var requestJson = new JObject
            {
                ["model"] = BuildConfig.PostProcessingModel,
                ["messages"] = new JArray
                {
                    new JObject { ["role"] = "system", ["content"] = systemPrompt },
                    new JObject { ["role"] = "user", ["content"] = userContent }
                },
                ["max_tokens"] = EstimateCompletionTokens(rawText),
                ["temperature"] = 0.0
            };

            using var request = new HttpRequestMessage(HttpMethod.Post, BuildConfig.PostProcessingEndpoint)
            {
                Content = new StringContent(requestJson.ToString(), Encoding.UTF8, "application/json")
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", apiKey);

            var response = await _httpClient.SendAsync(request, cancellationToken);
            if (!response.IsSuccessStatusCode)
            {
                Debug.WriteLine($"[LanguagePostProcess] Request failed: {(int)response.StatusCode}");
                return rawText;
            }

            var json = JObject.Parse(await response.Content.ReadAsStringAsync(cancellationToken));
            var choice = json["choices"]?[0];
            var corrected = choice?["message"]?["content"]?.ToString()?.Trim();

            // A truncated correction silently loses the tail of the dictation;
            // the raw transcript beats a cut-off "improvement".
            if (string.Equals(choice?["finish_reason"]?.ToString(), "length", StringComparison.OrdinalIgnoreCase))
            {
                Debug.WriteLine("[LanguagePostProcess] Completion truncated, returning raw text");
                return rawText;
            }

            return string.IsNullOrWhiteSpace(corrected) ? rawText : corrected;
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[LanguagePostProcess] Error: {ex.Message}");
            return rawText;
        }
    }

    // MARK: - Private Methods

    private static string BuildSystemPrompt(string? contextRules)
    {
        var prompt = new StringBuilder();
        prompt.Append("Correct basic errors in the transcription:\n");
        prompt.Append("Split improperly merged words (e.g., \"заросмова\" → \"зараз мова\").\n");
        prompt.Append("Correct obvious spelling and grammatical forms (e.g., \"украинська\" → \"українська\").\n");
        prompt.Append("Fix missing apostrophes and capitalization (e.g., \"dont\" → \"don't\").\n");
        prompt.Append("Clean up stutters and repeated words or phrases.\n\n");
        prompt.Append("STRICT CONSTRAINTS:\n");
        prompt.Append("DO NOT translate, rephrase, or summarize the text.\n");
        prompt.Append("DO NOT remove any spoken concepts or skip unrecognizable words. If unsure about a word, leave it exactly as-is.\n");
        prompt.Append("Keep the corrected text in the original language spoken.\n\n");

        if (!string.IsNullOrWhiteSpace(contextRules))
        {
            prompt.Append($"Additional instructions: {contextRules}\n\n");
        }

        prompt.Append("OUTPUT FORMAT:\n");
        prompt.Append("Return ONLY the corrected transcription text. Do not include the transcription number, language labels, explanations, or quotation marks.");

        return prompt.ToString();
    }

    private static int EstimateCompletionTokens(string text)
    {
        // Roughly one token per three characters, doubled for headroom so long
        // dictations are never truncated mid-sentence.
        var estimate = text.Length * 2 / 3;
        return Math.Clamp(estimate, Constants.MinCompletionTokens, Constants.MaxCompletionTokens);
    }
}
