using System;
using System.Reflection;
using AIDictation.Helpers;
using Sentry;

namespace AIDictation.Services;

/// <summary>
/// Initializes Sentry crash reporting and captures high-value handled failures
/// for Windows dictation, auth, and text insertion.
/// </summary>
public static class SentryTelemetry
{
    private static class Constants
    {
        public const string DefaultDsn =
            "https://3c6df4e50fce3b3955b33514a0c37a64@o4505732389470208.ingest.us.sentry.io/4512029576855552";
        public const double TracesSampleRate = 0.05;
    }

    private static bool _started;

    public static void Start()
    {
        if (_started)
        {
            return;
        }

        var dsn = BuildConfig.SentryDsn;
        if (string.IsNullOrWhiteSpace(dsn))
        {
            dsn = Constants.DefaultDsn;
        }

        SentrySdk.Init(options =>
        {
            options.Dsn = dsn;
            options.Environment = environmentName;
            options.Release = releaseName;
            options.IsGlobalModeEnabled = true;
            options.MaxBreadcrumbs = 100;
            options.AutoSessionTracking = true;
            options.TracesSampleRate = Constants.TracesSampleRate;
            options.DiagnosticLevel = SentryLevel.Warning;
        });

        _started = true;
        HighValueErrorSink.CaptureError = CaptureError;
        HighValueErrorSink.CaptureTextInsertFailure = CaptureTextInsertFailure;
        SentrySdk.ConfigureScope(scope =>
        {
            scope.SetTag("platform", "windows");
            scope.SetTag("app.bundle_id", Assembly.GetExecutingAssembly().GetName().Name ?? "AIDictation");
            scope.SetTag("os.version", Environment.OSVersion.VersionString);
        });
        SentrySdk.AddBreadcrumb("sentry_started", "app.lifecycle");
    }

    public static void CaptureError(string message, string? context = null, string? feature = null)
    {
        if (!_started || string.IsNullOrWhiteSpace(message))
        {
            return;
        }

        SentrySdk.CaptureMessage(
            context == null ? message : $"[{context}] {message}",
            scope => ApplyTags(scope, context, feature),
            SentryLevel.Error);
    }

    public static void CaptureException(Exception exception, string? context = null, string? feature = null)
    {
        if (!_started || exception == null)
        {
            return;
        }

        SentrySdk.CaptureException(exception, scope => ApplyTags(scope, context, feature));
    }

    public static void CaptureTextInsertFailure(string message, string reason)
    {
        if (!_started || string.IsNullOrWhiteSpace(message))
        {
            return;
        }

        SentrySdk.CaptureMessage(
            $"[ClipboardService] {message}",
            scope =>
            {
                ApplyTags(scope, "ClipboardService", "text_insert");
                scope.SetTag("text_insert.reason", reason);
            },
            SentryLevel.Error);
    }

    private static void ApplyTags(Scope scope, string? context, string? feature)
    {
        scope.SetTag("platform", "windows");
        scope.SetTag("feature", feature ?? FeatureName(context));
        if (!string.IsNullOrWhiteSpace(context))
        {
            scope.SetTag("error.context", context);
        }
    }

    private static string FeatureName(string? context)
    {
        var lowered = (context ?? "").ToLowerInvariant();
        if (lowered.Contains("auth") || lowered.Contains("sign"))
        {
            return "auth";
        }
        if (lowered.Contains("transcri") || lowered.Contains("audio"))
        {
            return "transcription";
        }
        if (lowered.Contains("clipboard") || lowered.Contains("paste") || lowered.Contains("insert"))
        {
            return "text_insert";
        }
        return string.IsNullOrWhiteSpace(context) ? "app" : context;
    }

    private static string releaseName
    {
        get
        {
            var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString() ?? "0.0.0";
            return $"AIDictation.Windows@{version}";
        }
    }

    private static string environmentName =>
#if DEBUG
        "debug";
#else
        "production";
#endif
}
