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
        public const string TranscriptionModel = "groq/whisper-large-v3-turbo";
        public const string PostProcessingEndpoint = "https://writingmate.ai/api/openai/v1/chat/completions";
        public const string PostProcessingModel = "openai/gpt-oss-20b";
        public const string AuthWebUrl = "https://voicesinmyhead.co/auth";
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
    public static string SupabaseUrl => Get("SUPABASE_URL", string.Empty).TrimEnd('/');
    public static string SupabaseAnonKey => Get("SUPABASE_ANON_KEY", string.Empty);
    public static string AuthWebUrl => Get("AUTH_WEB_URL", Defaults.AuthWebUrl);
    public static string StripePaymentLink => Get("STRIPE_PAYMENT_LINK", string.Empty);

    public static bool IsAuthConfigured =>
        !string.IsNullOrWhiteSpace(SupabaseUrl) &&
        !string.IsNullOrWhiteSpace(SupabaseAnonKey) &&
        !string.IsNullOrWhiteSpace(AuthWebUrl);

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
