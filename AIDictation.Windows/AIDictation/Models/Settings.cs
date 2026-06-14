using System.Collections.Generic;
using System.Windows.Input;
using Newtonsoft.Json;

namespace AIDictation.Models;

public class AppSettings
{
    public const string CloudTranscriptionProvider = "aidictation";
    public const string LocalTranscriptionProvider = "local";
    public const string AutoTranscriptionProvider = "auto";

    [JsonProperty("hotkey")]
    public Hotkey? Hotkey { get; set; } = new(Key.F8);

    [JsonProperty("commandHotkey")]
    public Hotkey? CommandHotkey { get; set; } = new(Key.F9, ModifierKeys.Control);

    [JsonProperty("pushToTalk")]
    public bool PushToTalk { get; set; } = true;

    [JsonProperty("overlayPosition")]
    public OverlayPosition OverlayPosition { get; set; } = OverlayPosition.Bottom;

    [JsonProperty("hideIdleOverlay")]
    public bool HideIdleOverlay { get; set; } = false;

    [JsonProperty("overlayColorTheme")]
    public OverlayColorTheme OverlayColorTheme { get; set; } = OverlayColorTheme.Orange;

    [JsonProperty("launchAtStartup")]
    public bool LaunchAtStartup { get; set; } = false;

    [JsonProperty("muteAudioWhenRecording")]
    public bool MuteAudioWhenRecording { get; set; } = true;

    [JsonProperty("selectedAudioDeviceId")]
    public string? SelectedAudioDeviceId { get; set; }

    [JsonProperty("selectedLanguages")]
    public List<string> SelectedLanguages { get; set; } = new() { "auto" };

    [JsonProperty("transcriptionProvider")]
    public string TranscriptionProvider { get; set; } = CloudTranscriptionProvider;

    [JsonProperty("enableLLMPostProcessing")]
    public bool EnableLLMPostProcessing { get; set; } = true;

    [JsonProperty("postProcessingProvider")]
    public string PostProcessingProvider { get; set; } = "aidictation";

    [JsonProperty("onboardingCompleted")]
    public bool OnboardingCompleted { get; set; } = false;

    [JsonProperty("currentOnboardingStep")]
    public int CurrentOnboardingStep { get; set; } = 0;
}

public enum OverlayPosition
{
    Top,
    Bottom
}

public enum OverlayColorTheme
{
    Orange,
    Blue,
    Green,
    Purple,
    Pink,
    Graphite
}

public class DictionaryEntry
{
    [JsonProperty("id")]
    public string Id { get; set; } = Guid.NewGuid().ToString();

    [JsonProperty("trigger")]
    public string Trigger { get; set; } = string.Empty;

    [JsonProperty("replacement")]
    public string? Replacement { get; set; }

    [JsonProperty("isEnabled")]
    public bool IsEnabled { get; set; } = true;
}

public class Shortcut
{
    [JsonProperty("id")]
    public string Id { get; set; } = Guid.NewGuid().ToString();

    [JsonProperty("voiceTrigger")]
    public string VoiceTrigger { get; set; } = string.Empty;

    [JsonProperty("expansion")]
    public string Expansion { get; set; } = string.Empty;

    [JsonProperty("isEnabled")]
    public bool IsEnabled { get; set; } = true;
}

public class ContextRule
{
    [JsonProperty("id")]
    public string Id { get; set; } = Guid.NewGuid().ToString();

    [JsonProperty("name")]
    public string Name { get; set; } = string.Empty;

    [JsonProperty("processNames")]
    public List<string> ProcessNames { get; set; } = new();

    [JsonProperty("titlePatterns")]
    public List<string> TitlePatterns { get; set; } = new();

    [JsonProperty("instructions")]
    public string Instructions { get; set; } = string.Empty;

    [JsonProperty("isEnabled")]
    public bool IsEnabled { get; set; } = true;
}
