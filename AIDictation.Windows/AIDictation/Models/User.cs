using System;
using Newtonsoft.Json;

namespace AIDictation.Models;

/// <summary>
/// User profile from the Supabase "profiles" table, matching the Android/macOS schema.
/// </summary>
public class User
{
    [JsonProperty("id")]
    public Guid Id { get; set; }

    [JsonProperty("user_id")]
    public Guid UserId { get; set; }

    [JsonProperty("email")]
    public string Email { get; set; } = string.Empty;

    [JsonProperty("monthly_word_count")]
    public int MonthlyWordCount { get; set; }

    [JsonProperty("subscription_status")]
    public string SubscriptionStatus { get; set; } = "free";

    [JsonProperty("created_at")]
    public DateTime? CreatedAt { get; set; }

    [JsonProperty("updated_at")]
    public DateTime? UpdatedAt { get; set; }

    [JsonProperty("stripe_customer_id")]
    public string? StripeCustomerId { get; set; }

    [JsonProperty("stripe_subscription_id")]
    public string? StripeSubscriptionId { get; set; }

    [JsonProperty("word_count_reset_at")]
    public DateTime? WordCountResetAt { get; set; }

    [JsonIgnore]
    public SubscriptionTier SubscriptionTier =>
        SubscriptionStatus?.Trim().ToLowerInvariant() switch
        {
            "pro" => SubscriptionTier.Pro,
            "lifetime" => SubscriptionTier.Lifetime,
            _ => SubscriptionTier.Free
        };

    [JsonIgnore]
    public int TotalWordsUsed => MonthlyWordCount;

    [JsonIgnore]
    public int WordsRemaining
    {
        get
        {
            var limit = SubscriptionTier.GetWordLimit();
            return limit == int.MaxValue ? int.MaxValue : Math.Max(0, limit - MonthlyWordCount);
        }
    }

    [JsonIgnore]
    public bool HasReachedLimit =>
        SubscriptionTier.GetWordLimit() != int.MaxValue &&
        MonthlyWordCount >= SubscriptionTier.GetWordLimit();

    [JsonIgnore]
    public double UsagePercentage
    {
        get
        {
            var limit = SubscriptionTier.GetWordLimit();
            return limit == int.MaxValue ? 0.0 : (double)MonthlyWordCount / limit;
        }
    }

    [JsonIgnore]
    public bool NeedsWordCountReset
    {
        get
        {
            if (SubscriptionTier.IsPaid()) return false;
            if (WordCountResetAt == null) return false;
            return DateTime.UtcNow >= WordCountResetAt;
        }
    }
}

public enum SubscriptionTier
{
    Free,
    Pro,
    Lifetime
}

public static class SubscriptionTierExtensions
{
    public const int FreeMonthlyWordLimit = 2000;

    /// <summary>True for any paid tier (Pro or Lifetime) — unlimited usage.</summary>
    public static bool IsPaid(this SubscriptionTier tier) =>
        tier is SubscriptionTier.Pro or SubscriptionTier.Lifetime;

    public static string GetDisplayName(this SubscriptionTier tier) => tier switch
    {
        SubscriptionTier.Free => "Free Trial",
        SubscriptionTier.Pro => "Pro",
        SubscriptionTier.Lifetime => "Lifetime",
        _ => "Unknown"
    };

    public static int GetWordLimit(this SubscriptionTier tier) => tier switch
    {
        SubscriptionTier.Free => FreeMonthlyWordLimit,
        SubscriptionTier.Pro => int.MaxValue,
        SubscriptionTier.Lifetime => int.MaxValue,
        _ => FreeMonthlyWordLimit
    };

    public static string GetPrice(this SubscriptionTier tier) => tier switch
    {
        SubscriptionTier.Free => "$0",
        SubscriptionTier.Pro => "$9.99/month",
        SubscriptionTier.Lifetime => "One-time",
        _ => "$0"
    };

    public static string[] GetFeatures(this SubscriptionTier tier) => tier switch
    {
        SubscriptionTier.Free => new[]
        {
            $"{FreeMonthlyWordLimit:N0} words/month",
            "Full transcription features",
            "Local storage"
        },
        SubscriptionTier.Pro => new[]
        {
            "Unlimited transcriptions",
            "Included API access",
            "Priority support",
            "Cloud sync (coming soon)"
        },
        SubscriptionTier.Lifetime => new[]
        {
            "Unlimited transcriptions, forever",
            "Included API access",
            "Priority support",
            "Cloud sync (coming soon)"
        },
        _ => Array.Empty<string>()
    };
}
