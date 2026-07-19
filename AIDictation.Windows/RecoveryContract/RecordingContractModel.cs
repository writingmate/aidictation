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

public sealed class Recording
{
    public Guid Id { get; set; }
    public DateTime Timestamp { get; set; }
    public string AudioFilePath { get; set; } = string.Empty;
    public string? Transcription { get; set; }
    public string? RawTranscription { get; set; }
    public string? CheckpointTranscription { get; set; }
    public TranscriptionStatus Status { get; set; }
    public string? ErrorMessage { get; set; }
    public int RetryCount { get; set; }
    public RecordingSourceIntegrity SourceIntegrity { get; set; }
    public long Revision { get; set; }
    public double? Duration { get; set; }
    public int? WordCount { get; set; }

    public bool CanRetry =>
        Status is not (TranscriptionStatus.Processing or TranscriptionStatus.Retrying) &&
        SourceIntegrity == RecordingSourceIntegrity.Complete &&
        !string.IsNullOrWhiteSpace(AudioFilePath) &&
        File.Exists(AudioFilePath);
}
