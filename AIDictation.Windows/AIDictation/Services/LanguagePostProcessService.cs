using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Net;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using AIDictation.Helpers;

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
    private readonly Uri _endpoint;
    private readonly string _apiKey;
    private readonly string _model;
    private readonly TimeSpan _deadline;

    // MARK: - Initialization

    private LanguagePostProcessService() : this(
        new HttpClient { Timeout = Timeout.InfiniteTimeSpan },
        new Uri(BuildConfig.PostProcessingEndpoint),
        BuildConfig.PostProcessingApiKey,
        BuildConfig.PostProcessingModel,
        TimeSpan.FromSeconds(Constants.HttpTimeoutSeconds))
    {
    }

    public LanguagePostProcessService(
        HttpClient httpClient,
        Uri endpoint,
        string apiKey,
        string model,
        TimeSpan deadline)
    {
        _httpClient = httpClient;
        _httpClient.Timeout = Timeout.InfiniteTimeSpan;
        _endpoint = endpoint;
        _apiKey = apiKey;
        _model = model;
        _deadline = deadline;
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
        TranscriptionAttemptSnapshot snapshot,
        CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrWhiteSpace(rawText)) return rawText;

        if (string.IsNullOrEmpty(_apiKey))
        {
            Debug.WriteLine("[LanguagePostProcess] API key not configured, skipping");
            return rawText;
        }

        var systemPrompt = TranscriptionCleanupPrompt.BuildSystemInstructions();
        var referenceBlock = snapshot.CleanupReferenceBlock ??
                             TranscriptionCleanupPrompt.BuildReferenceBlock(
                                 snapshot.Vocabulary ?? Array.Empty<string>(),
                                 snapshot.Replacements,
                                 snapshot.Expansions,
                                 snapshot.ContextInstructions);
        IReadOnlyList<string> selectedLanguages = languageNames.Count > 0
            ? languageNames
            : new[] { "auto" };
        var languageLine = $"selected_languages={JsonSerializer.Serialize(selectedLanguages)}";
        var userContent = languageLine + "\n" +
                          TranscriptionCleanupPrompt.BuildOfflineUserContent(rawText, referenceBlock);

        try
        {
            using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            deadline.CancelAfter(_deadline);
            var requestJson = JsonSerializer.Serialize(new
            {
                model = _model,
                messages = new[]
                {
                    new { role = "system", content = systemPrompt },
                    new { role = "user", content = userContent }
                },
                max_tokens = EstimateCompletionTokens(rawText),
                temperature = 0.0
            });

            using var request = new HttpRequestMessage(HttpMethod.Post, _endpoint)
            {
                Content = new StringContent(requestJson, Encoding.UTF8, "application/json")
            };
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", _apiKey);

            var sendTask = Task.Run(
                () => _httpClient.SendAsync(
                    request,
                    HttpCompletionOption.ResponseHeadersRead,
                    deadline.Token),
                CancellationToken.None);
            HttpResponseMessage response;
            try
            {
                response = await sendTask.WaitAsync(deadline.Token).ConfigureAwait(false);
            }
            catch
            {
                DisposeLateResponse(sendTask);
                throw;
            }

            using (response)
            {
                var bodyTask = Task.Run(
                    () => response.Content.ReadAsStringAsync(deadline.Token),
                    CancellationToken.None);
                string responseBody;
                try
                {
                    responseBody = await bodyTask.WaitAsync(deadline.Token).ConfigureAwait(false);
                }
                catch
                {
                    ObserveLateTask(bodyTask);
                    throw;
                }
                if (!CleanupCompletionPolicy.TryAccept(response.StatusCode, responseBody, out var corrected))
                {
                    Debug.WriteLine($"[LanguagePostProcess] Incomplete cleanup response ({(int)response.StatusCode}), returning raw text");
                    return rawText;
                }

                return corrected;
            }
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (OperationCanceledException)
        {
            Debug.WriteLine("[LanguagePostProcess] Cleanup timed out, returning raw text");
            return rawText;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[LanguagePostProcess] Error: {ex.Message}");
            return rawText;
        }
    }

    // MARK: - Private Methods

    private static int EstimateCompletionTokens(string text)
    {
        // Roughly one token per three characters, doubled for headroom so long
        // dictations are never truncated mid-sentence.
        var estimate = text.Length * 2 / 3;
        return Math.Clamp(estimate, Constants.MinCompletionTokens, Constants.MaxCompletionTokens);
    }

    private static void DisposeLateResponse(Task<HttpResponseMessage> task)
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

    private static void ObserveLateTask(Task task)
    {
        _ = task.ContinueWith(
            completed => _ = completed.Exception,
            CancellationToken.None,
            TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously,
            TaskScheduler.Default);
    }
}
