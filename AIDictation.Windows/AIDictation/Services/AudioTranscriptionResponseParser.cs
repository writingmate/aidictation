using System;
using System.Linq;
using System.Text.Json;

namespace AIDictation.Services;

public static class AudioTranscriptionResponseParser
{
    public static string ParseCompleteText(string body, string? mediaType)
    {
        if (string.IsNullOrWhiteSpace(body))
            throw new InvalidAudioResponseException("The transcription service returned an empty response.");

        var trimmed = body.Trim();
        var isJson = string.Equals(mediaType, "application/json", StringComparison.OrdinalIgnoreCase) ||
                     mediaType?.EndsWith("+json", StringComparison.OrdinalIgnoreCase) == true;
        if (!isJson) return trimmed;

        try
        {
            using var document = JsonDocument.Parse(trimmed);
            if (document.RootElement.ValueKind != JsonValueKind.Object)
                throw Invalid();
            var properties = document.RootElement.EnumerateObject().ToArray();
            if (properties.Length != 1 ||
                properties[0].Name is not ("text" or "transcript" or "transcription") ||
                properties[0].Value.ValueKind != JsonValueKind.String)
                throw Invalid();
            var text = properties[0].Value.GetString()?.Trim();
            return string.IsNullOrWhiteSpace(text)
                ? throw new InvalidAudioResponseException("The transcription service returned no text.")
                : text;
        }
        catch (InvalidAudioResponseException) { throw; }
        catch (JsonException ex)
        {
            throw new InvalidAudioResponseException(
                "The transcription service returned an invalid response. The recording was kept.", ex);
        }
    }

    private static InvalidAudioResponseException Invalid() => new(
        "The transcription service returned an invalid response. The recording was kept.");
}
