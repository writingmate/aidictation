using System;
using System.Collections.Generic;
using System.Reflection;

namespace AIDictation.Helpers;

/// <summary>
/// Build-time configuration injected via MSBuild AssemblyMetadata attributes,
/// with environment variable overrides for development and hardcoded defaults.
/// Mirrors the Android BuildConfig / configValue() pattern.
/// </summary>
public static class BuildConfig
{
    // MARK: - Constants

    private static class Defaults
    {
        public const string TranscriptionEndpoint = "https://writingmate.ai/api/openai/v1/audio/transcriptions";
        public const string TranscriptionModel = "soniox/stt-async-v5";
        public const string PostProcessingEndpoint = "https://writingmate.ai/api/openai/v1/chat/completions";
        public const string PostProcessingModel = "openai/gpt-oss-20b";

        /// <summary>Origin serving both the sign-in page and the auth/profile API.</summary>
        public const string AuthBackendHost = "aidictation.com";
        public const string AuthBackendOrigin = "https://" + AuthBackendHost;
        public const string AuthWebUrl = AuthBackendOrigin + "/auth";

        /// <summary>
        /// Defaults to the origin that serves <see cref="AuthWebUrl"/>. A build that
        /// left this empty reported "auth not configured"; one that pointed it at a
        /// different backend collected a session from the sign-in page and sent it to
        /// an API that rejects it.
        /// </summary>
        public const string SupabaseUrl = AuthBackendOrigin;
    }

    // MARK: - Private Properties

    private static readonly Lazy<Dictionary<string, string>> _metadata = new(LoadAssemblyMetadata);

    // MARK: - Public API

    public static string TranscriptionEndpoint => Get("TRANSCRIPTION_ENDPOINT", Defaults.TranscriptionEndpoint);
    public static string TranscriptionModel => Get("TRANSCRIPTION_MODEL", Defaults.TranscriptionModel);
    public static string TranscriptionApiKey => Get("TRANSCRIPTION_API_KEY", string.Empty);
    public static string PostProcessingEndpoint => Get("AIDICTATION_POST_PROCESSING_ENDPOINT", Defaults.PostProcessingEndpoint);
    public static string PostProcessingModel => Get("AIDICTATION_POST_PROCESSING_MODEL", Defaults.PostProcessingModel);
    public static string PostProcessingApiKey => Get("AIDICTATION_POST_PROCESSING_KEY", string.Empty);
    public static string SupabaseUrl => Get("SUPABASE_URL", Defaults.SupabaseUrl).TrimEnd('/');

    // The Cloudflare backend authenticates from the bearer token alone and ignores
    // this header, but a blank value reads as "auth not configured".
    public static string SupabaseAnonKey => Get(
        "SUPABASE_ANON_KEY",
        HostOf(Defaults.SupabaseUrl) == Defaults.AuthBackendHost ? "public-anon-key" : string.Empty);

    public static string AuthWebUrl => Get("AUTH_WEB_URL", Defaults.AuthWebUrl);
    public static string StripePaymentLink => Get("STRIPE_PAYMENT_LINK", string.Empty);
    public static string SentryDsn => Get("SENTRY_DSN", string.Empty);

    public static bool IsAuthConfigured =>
        !string.IsNullOrWhiteSpace(SupabaseUrl) &&
        !string.IsNullOrWhiteSpace(SupabaseAnonKey) &&
        !string.IsNullOrWhiteSpace(AuthWebUrl) &&
        AuthBackendsAgree;

    /// <summary>
    /// The sign-in page mints the session and the API has to validate it. When the
    /// two point at different backends the token is rejected, so report the config
    /// as unusable rather than letting sign-in appear to work and then fail.
    /// </summary>
    public static bool AuthBackendsAgree
    {
        get
        {
            var authHost = HostOf(AuthWebUrl);
            var apiHost = HostOf(SupabaseUrl);
            if (authHost.Length == 0 || apiHost.Length == 0) return false;
            if (authHost == apiHost) return true;
            // The legacy split (a standalone auth page in front of Supabase) predates
            // the migration; only the Cloudflare origin has to match on both sides.
            return authHost != Defaults.AuthBackendHost && apiHost != Defaults.AuthBackendHost;
        }
    }

    private static string HostOf(string url) =>
        Uri.TryCreate(url, UriKind.Absolute, out var parsed) ? parsed.Host.ToLowerInvariant() : string.Empty;

    // MARK: - Private Methods

    private static string Get(string key, string fallback)
    {
        var env = Environment.GetEnvironmentVariable(key);
        if (!string.IsNullOrWhiteSpace(env))
        {
            return env;
        }

        return _metadata.Value.TryGetValue(key, out var value) && !string.IsNullOrWhiteSpace(value)
            ? value
            : fallback;
    }

    private static Dictionary<string, string> LoadAssemblyMetadata()
    {
        var result = new Dictionary<string, string>(StringComparer.Ordinal);
        var attributes = Assembly.GetExecutingAssembly()
            .GetCustomAttributes<AssemblyMetadataAttribute>();

        foreach (var attribute in attributes)
        {
            if (!string.IsNullOrEmpty(attribute.Key) && attribute.Value != null)
            {
                result[attribute.Key] = attribute.Value;
            }
        }

        return result;
    }
}
