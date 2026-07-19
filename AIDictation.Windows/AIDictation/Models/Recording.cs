using System;
using System.IO;
using Newtonsoft.Json;

namespace AIDictation.Models;

public enum TranscriptionStatus
{
    Processing,
    Success,
    Failed,
    Retrying,
    Cancelled
}

public enum RecordingSourceIntegrity
{
    Complete,
    KnownIncomplete,
    Unfinalized
}

public class Recording
{
    [JsonProperty("id")]
    public Guid Id { get; set; } = Guid.NewGuid();

    [JsonProperty("timestamp")]
    public DateTime Timestamp { get; set; } = DateTime.Now;

    [JsonProperty("audioFilePath")]
    public string AudioFilePath { get; set; } = string.Empty;

    [JsonProperty("transcription")]
    public string? Transcription { get; set; }

    [JsonProperty("rawTranscription")]
    public string? RawTranscription { get; set; }

    [JsonProperty("checkpointTranscription")]
    public string? CheckpointTranscription { get; set; }

    [JsonProperty("status")]
    public TranscriptionStatus Status { get; set; } = TranscriptionStatus.Success;

    [JsonProperty("errorMessage")]
    public string? ErrorMessage { get; set; }

    [JsonProperty("retryCount")]
    public int RetryCount { get; set; }

    [JsonProperty("sourceIntegrity")]
    public RecordingSourceIntegrity SourceIntegrity { get; set; } = RecordingSourceIntegrity.Complete;

    [JsonProperty("revision")]
    public long Revision { get; set; }

    [JsonProperty("duration")]
    public double? Duration { get; set; }

    [JsonProperty("wordCount")]
    public int? WordCount { get; set; }

    [JsonIgnore]
    public string FormattedDate => Timestamp.ToString("g");

    [JsonIgnore]
    public string? FormattedDuration
    {
        get
        {
            if (Duration == null) return null;
            var minutes = (int)(Duration.Value / 60);
            var seconds = (int)(Duration.Value % 60);
            return minutes > 0 ? $"{minutes}:{seconds:D2}" : $"{seconds}s";
        }
    }

    [JsonIgnore]
    public bool IsSuccessful => Status == TranscriptionStatus.Success;

    [JsonIgnore]
    public bool IsFailed => Status == TranscriptionStatus.Failed;

    [JsonIgnore]
    public bool IsInProgress => Status is TranscriptionStatus.Processing or TranscriptionStatus.Retrying;

    [JsonIgnore]
    public bool CanRetry => !IsInProgress && SourceIntegrity == RecordingSourceIntegrity.Complete &&
                            !string.IsNullOrWhiteSpace(AudioFilePath) && File.Exists(AudioFilePath);
}
