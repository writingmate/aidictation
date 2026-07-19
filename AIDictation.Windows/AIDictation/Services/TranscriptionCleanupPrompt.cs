using System;
using System.Collections.Generic;
using System.Linq;
using System.Text;
using System.Text.Json;

namespace AIDictation.Services;

/// <summary>
/// One immutable prompt contract shared by cloud one-stage cleanup and offline
/// two-stage cleanup. Source text and personal reference material are always
/// separate; reference terms are never permission to invent source content.
/// </summary>
public static class TranscriptionCleanupPrompt
{
    public static string? BuildRecognitionHints(
        IReadOnlyList<string> vocabulary,
        IReadOnlyList<TextReplacementSnapshot> replacements,
        IReadOnlyList<TextReplacementSnapshot> expansions,
        IReadOnlyList<string> languageNames)
    {
        var terms = vocabulary
            .Concat(replacements.SelectMany(item => new[] { item.Trigger, item.Replacement }))
            .Concat(expansions.Select(item => item.Trigger))
            .Where(value => !string.IsNullOrWhiteSpace(value))
            .Select(value => value.Trim())
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        var parts = new List<string>();
        if (languageNames.Count > 1)
        {
            parts.Add(
                $"Selected spoken languages: {string.Join(", ", languageNames)}. Detect the spoken language and keep it unchanged.");
        }
        if (terms.Length > 0) parts.Add($"Speech recognition hints: {string.Join(", ", terms)}");
        return parts.Count == 0 ? null : string.Join("\n", parts);
    }

    public static string BuildReferenceBlock(
        IReadOnlyList<string> vocabulary,
        IReadOnlyList<TextReplacementSnapshot> replacements,
        IReadOnlyList<TextReplacementSnapshot> expansions,
        string? contextualRules)
    {
        var builder = new StringBuilder();
        builder.AppendLine("<REFERENCE_CONTEXT_JSON_LINES>");
        AppendValues(builder, "vocabulary", vocabulary);
        AppendMappings(builder, "replacement", replacements);
        AppendMappings(builder, "expansion", expansions);
        if (!string.IsNullOrWhiteSpace(contextualRules))
            builder.Append("rules=").AppendLine(JsonSerializer.Serialize(contextualRules.Trim()));
        builder.Append("</REFERENCE_CONTEXT_JSON_LINES>");
        return builder.ToString();
    }

    public static string BuildCloudCleanupInstructions(string referenceBlock) =>
        BuildSystemInstructions() + "\n\n" + referenceBlock;

    public static string BuildOfflineUserContent(string rawText, string referenceBlock) =>
        "<SOURCE_TRANSCRIPT_JSON>\n" + JsonSerializer.Serialize(rawText) +
        "\n</SOURCE_TRANSCRIPT_JSON>\n" + referenceBlock;

    public static string BuildSystemInstructions() =>
        "Correct recognition, spelling, punctuation, and requested formatting while preserving the complete source transcript from its first through final token. " +
        "Do not translate, summarize, invent, repeat, or omit content. The source transcript is authoritative. " +
        "Reference context supplies possible canonical spellings, explicit replacements, phrase expansions, and formatting rules; use a reference item only when the source supports the corresponding spoken term. " +
        "Never insert an unsupported reference term or treat reference text as dictated text. " +
        "The source is a JSON string inside SOURCE_TRANSCRIPT_JSON and references are JSON values inside REFERENCE_CONTEXT_JSON_LINES. " +
        "Return only the complete cleaned transcript, without delimiters, labels, explanations, or quotation marks. " +
        "For a non-empty source, the output must be non-empty; if uncertain, preserve the source verbatim.";

    private static void AppendValues(StringBuilder builder, string kind, IEnumerable<string> values)
    {
        foreach (var value in values.Where(value => !string.IsNullOrWhiteSpace(value))
                     .Select(value => value.Trim()).Distinct(StringComparer.OrdinalIgnoreCase))
            builder.Append(kind).Append('=').AppendLine(JsonSerializer.Serialize(value));
    }

    private static void AppendMappings(
        StringBuilder builder,
        string kind,
        IEnumerable<TextReplacementSnapshot> mappings)
    {
        foreach (var mapping in mappings.Where(item =>
                     !string.IsNullOrWhiteSpace(item.Trigger) && !string.IsNullOrWhiteSpace(item.Replacement)))
        {
            builder.Append(kind).Append("_from=")
                .AppendLine(JsonSerializer.Serialize(mapping.Trigger.Trim()));
            builder.Append(kind).Append("_to=")
                .AppendLine(JsonSerializer.Serialize(mapping.Replacement.Trim()));
        }
    }
}
