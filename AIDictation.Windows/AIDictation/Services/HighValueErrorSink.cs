namespace AIDictation.Services;

/// <summary>
/// Optional sink for high-value handled failures. The Windows app registers
/// Sentry in <c>SentryTelemetry.Start</c>. InsertTest and RecoveryContract
/// compile production services without the Sentry package and leave this unset.
/// </summary>
public static class HighValueErrorSink
{
    public static Action<string, string?, string?>? CaptureError { get; set; }
    public static Action<string, string>? CaptureTextInsertFailure { get; set; }

    public static void ReportError(string message, string? context = null, string? feature = null)
    {
        CaptureError?.Invoke(message, context, feature);
    }

    public static void ReportTextInsertFailure(string message, string reason)
    {
        CaptureTextInsertFailure?.Invoke(message, reason);
    }
}
