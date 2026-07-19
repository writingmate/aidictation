using System;
using System.Net;
using System.Text.Json;

namespace AIDictation.Services;

/// <summary>
/// A cleanup result is usable only when the entire completion arrived under
/// the one accepted success status. Every other outcome falls back to raw text.
/// </summary>
public static class CleanupCompletionPolicy
{
    public static bool TryAccept(
        HttpStatusCode statusCode,
        string responseBody,
        out string cleanedText)
    {
        cleanedText = string.Empty;
        if (statusCode != HttpStatusCode.OK || string.IsNullOrWhiteSpace(responseBody)) return false;

        try
        {
            using var document = JsonDocument.Parse(responseBody);
            if (!document.RootElement.TryGetProperty("choices", out var choices) ||
                choices.ValueKind != JsonValueKind.Array ||
                choices.GetArrayLength() == 0)
                return false;

            var choice = choices[0];
            if (!choice.TryGetProperty("finish_reason", out var finishReason) ||
                finishReason.ValueKind != JsonValueKind.String ||
                !string.Equals(finishReason.GetString(), "stop", StringComparison.Ordinal))
                return false;
            if (!choice.TryGetProperty("message", out var message) ||
                message.ValueKind != JsonValueKind.Object ||
                !message.TryGetProperty("content", out var content) ||
                content.ValueKind != JsonValueKind.String)
                return false;

            cleanedText = content.GetString()?.Trim() ?? string.Empty;
            return !string.IsNullOrWhiteSpace(cleanedText);
        }
        catch (JsonException)
        {
            return false;
        }
    }
}
