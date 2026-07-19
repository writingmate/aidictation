using System;
using System.Collections.Generic;
using System.Linq;

namespace AIDictation.Services;

/// <summary>
/// Freezes every mutable setting used by an attempt and derives both prompt
/// shapes from that same immutable copy.
/// </summary>
public static class TranscriptionAttemptSnapshotFactory
{
    public static TranscriptionAttemptSnapshot Capture(
        string provider,
        IEnumerable<string> languageCodes,
        IEnumerable<string> languageNames,
        IEnumerable<string> vocabulary,
        IEnumerable<TextReplacementSnapshot> replacements,
        IEnumerable<TextReplacementSnapshot> expansions,
        string? contextInstructions,
        bool cleanupEnabled)
    {
        var capturedLanguageCodes = languageCodes.ToArray();
        var capturedLanguageNames = languageNames.ToArray();
        var capturedVocabulary = vocabulary
            .Select(value => value.Trim())
            .Where(value => value.Length > 0)
            .Distinct(StringComparer.OrdinalIgnoreCase)
            .ToArray();
        var capturedReplacements = replacements
            .Select(item => new TextReplacementSnapshot(item.Trigger, item.Replacement))
            .ToArray();
        var capturedExpansions = expansions
            .Select(item => new TextReplacementSnapshot(item.Trigger, item.Replacement))
            .ToArray();
        var capturedContext = contextInstructions;
        var reference = TranscriptionCleanupPrompt.BuildReferenceBlock(
            capturedVocabulary,
            capturedReplacements,
            capturedExpansions,
            capturedContext);
        var recognition = TranscriptionCleanupPrompt.BuildRecognitionHints(
            capturedVocabulary,
            capturedReplacements,
            capturedExpansions,
            capturedLanguageNames);

        return new TranscriptionAttemptSnapshot(
            provider,
            capturedLanguageCodes,
            recognition,
            cleanupEnabled
                ? TranscriptionCleanupPrompt.BuildCloudCleanupInstructions(reference)
                : null,
            cleanupEnabled,
            capturedReplacements,
            capturedExpansions,
            capturedContext,
            capturedVocabulary,
            reference);
    }
}
