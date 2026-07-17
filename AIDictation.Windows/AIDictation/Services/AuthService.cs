using System;
using System.Diagnostics;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Web;
using AIDictation.Helpers;
using CommunityToolkit.Mvvm.ComponentModel;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using UserProfile = AIDictation.Models.User;

namespace AIDictation.Services;

/// <summary>
/// Manages authentication against the WritingMate Supabase backend using the same
/// browser-based web auth flow as the Android and macOS apps: the system browser opens
/// AUTH_WEB_URL with redirect_to=aidictation://auth-callback, and the callback carries
/// access/refresh tokens which are stored in Windows Credential Manager.
/// </summary>
public partial class AuthService : ObservableObject
{
    // MARK: - Constants

    private static class Constants
    {
        public const string CallbackScheme = "aidictation";
        public const string CallbackHost = "auth-callback";
        public const int TokenRefreshBufferMinutes = 5;
        public const int HttpTimeoutSeconds = 30;
    }

    // MARK: - Singleton

    private static readonly Lazy<AuthService> _instance = new(() => new AuthService());
    public static AuthService Instance => _instance.Value;

    // MARK: - Published Properties

    [ObservableProperty]
    private bool _isAuthenticated;

    [ObservableProperty]
    private bool _isLoading;

    [ObservableProperty]
    private UserProfile? _currentUser;

    [ObservableProperty]
    private string? _errorMessage;

    // MARK: - Private Properties

    private readonly HttpClient _httpClient;
    private readonly SemaphoreSlim _tokenRefreshGate = new(1, 1);
    private readonly SemaphoreSlim _subscriptionReconciliationGate = new(1, 1);

    // MARK: - Events

    public event EventHandler? AuthStateChanged;

    // MARK: - Initialization

    private AuthService()
    {
        _httpClient = new HttpClient
        {
            Timeout = TimeSpan.FromSeconds(Constants.HttpTimeoutSeconds)
        };
    }

    // MARK: - Public API

    public static bool IsAuthConfigured => BuildConfig.IsAuthConfigured;

    /// <summary>
    /// Initializes authentication on app startup: loads the stored session,
    /// refreshes it when stale, and fetches the user profile.
    /// </summary>
    public async Task InitializeAsync()
    {
        if (!IsAuthConfigured)
        {
            IsAuthenticated = false;
            return;
        }

        IsLoading = true;
        ErrorMessage = null;

        try
        {
            var storedSession = CredentialHelper.LoadSession();
            if (storedSession == null)
            {
                IsAuthenticated = false;
                return;
            }

            var (accessToken, refreshToken, expiresAt) = storedSession.Value;

            if (DateTimeOffset.UtcNow.AddMinutes(Constants.TokenRefreshBufferMinutes) >= expiresAt)
            {
                var (outcome, refreshed) = await RefreshTokensAsync(refreshToken);
                if (outcome == RefreshOutcome.Rejected)
                {
                    ClearSessionState();
                    return;
                }
                if (outcome == RefreshOutcome.NetworkError)
                {
                    // Offline start: keep the stored session for the next launch
                    // instead of deleting a still-valid refresh token.
                    IsAuthenticated = false;
                    return;
                }
                accessToken = refreshed ?? string.Empty;
            }

            if (string.IsNullOrEmpty(accessToken))
            {
                ClearSessionState();
                return;
            }

            var profile = await FetchProfileAsync(accessToken);
            if (profile == null)
            {
                // Access token may be stale despite the expiry timestamp - try one refresh.
                var (retryOutcome, retryToken) = await RefreshTokensAsync(refreshToken);
                if (retryOutcome == RefreshOutcome.Rejected)
                {
                    ClearSessionState();
                    return;
                }
                if (!string.IsNullOrEmpty(retryToken))
                {
                    accessToken = retryToken;
                    profile = await FetchProfileAsync(accessToken);
                }
            }

            if (profile != null)
            {
                profile = await ReconcileProfileSubscriptionAsync(accessToken, profile);
                if (!IsCurrentSessionForUser(profile.UserId)) return;

                CurrentUser = profile;
                IsAuthenticated = true;
                AuthStateChanged?.Invoke(this, EventArgs.Empty);
            }
            // A profile fetch failing without a definitive token rejection
            // (backend or network down) keeps the stored session for later.
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[AuthService] Initialize error: {ex.Message}");
            ErrorMessage = "Failed to restore session";
            IsAuthenticated = false; // keep stored tokens; likely transient
        }
        finally
        {
            IsLoading = false;
        }
    }

    /// <summary>
    /// Opens the WritingMate web auth page in the default browser.
    /// The page redirects back via aidictation://auth-callback with tokens.
    /// </summary>
    public void OpenLogin()
    {
        if (!IsAuthConfigured)
        {
            ErrorMessage = "Sign-in is not configured in this build";
            return;
        }

        var redirectTo = $"{Constants.CallbackScheme}://{Constants.CallbackHost}";
        var separator = BuildConfig.AuthWebUrl.Contains('?') ? "&" : "?";
        var authUrl = $"{BuildConfig.AuthWebUrl}{separator}redirect_to={Uri.EscapeDataString(redirectTo)}";

        Process.Start(new ProcessStartInfo
        {
            FileName = authUrl,
            UseShellExecute = true
        });
    }

    /// <summary>
    /// Opens the hosted purchase page for the signed-in account.
    /// </summary>
    public void OpenUpgrade()
    {
        if (!TryOpenUpgrade(out var errorMessage))
        {
            ErrorMessage = errorMessage;
        }
    }

    /// <summary>
    /// Tries to hand off the signed-in account to hosted checkout. The caller
    /// owns the visible success or retry state because starting a browser only
    /// proves the handoff, not that a purchase was completed.
    /// </summary>
    public bool TryOpenUpgrade(out string? errorMessage)
    {
        errorMessage = null;
        var link = BuildConfig.RevenueCatWebPurchaseLink.Trim().TrimEnd('/');
        if (string.IsNullOrWhiteSpace(link))
        {
            errorMessage = "Checkout isn’t available right now. Please try again later.";
            return false;
        }

        if (CurrentUser == null)
        {
            errorMessage = "Sign in to continue to checkout.";
            return false;
        }

        if (!Uri.TryCreate(link, UriKind.Absolute, out var purchaseLink) ||
            purchaseLink.Scheme != Uri.UriSchemeHttps ||
            !purchaseLink.Host.Equals("pay.rev.cat", StringComparison.OrdinalIgnoreCase) ||
            !purchaseLink.IsDefaultPort ||
            !string.IsNullOrEmpty(purchaseLink.UserInfo) ||
            !string.IsNullOrEmpty(purchaseLink.Query) ||
            !string.IsNullOrEmpty(purchaseLink.Fragment) ||
            purchaseLink.AbsolutePath
                .Split('/', StringSplitOptions.RemoveEmptyEntries).Length != 1)
        {
            Debug.WriteLine("[AuthService] Checkout handoff failed: purchase link is invalid");
            errorMessage = "Checkout isn’t available right now. Please try again later.";
            return false;
        }

        var urlString =
            $"{purchaseLink.AbsoluteUri.TrimEnd('/')}/{Uri.EscapeDataString(CurrentUser.UserId.ToString().ToLowerInvariant())}" +
            $"?email={Uri.EscapeDataString(CurrentUser.Email)}";

        if (!Uri.TryCreate(urlString, UriKind.Absolute, out var checkoutUri) ||
            checkoutUri.Scheme != Uri.UriSchemeHttps)
        {
            Debug.WriteLine("[AuthService] Checkout handoff failed: generated URL is invalid");
            errorMessage = "Checkout isn’t available right now. Please try again later.";
            return false;
        }

        try
        {
            Process.Start(new ProcessStartInfo
            {
                FileName = checkoutUri.AbsoluteUri,
                UseShellExecute = true
            });
            return true;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[AuthService] Checkout handoff failed: {ex.Message}");
            errorMessage = "Your browser could not be opened. Check your default browser and try again.";
            return false;
        }
    }

    /// <summary>
    /// Handles the aidictation://auth-callback URL with access/refresh tokens
    /// in the query string or fragment.
    /// </summary>
    public async Task<bool> HandleOAuthCallbackAsync(Uri callbackUri)
    {
        try
        {
            var query = HttpUtility.ParseQueryString(callbackUri.Query);
            var fragment = HttpUtility.ParseQueryString(callbackUri.Fragment.TrimStart('#'));

            var accessToken = fragment["access_token"] ?? query["access_token"];
            var refreshToken = fragment["refresh_token"] ?? query["refresh_token"];

            if (string.IsNullOrEmpty(accessToken))
            {
                ErrorMessage = "Authentication callback did not include a session";
                return false;
            }

            SaveTokens(accessToken, refreshToken ?? string.Empty);

            IsLoading = true;
            var profile = await FetchProfileAsync(accessToken);
            if (profile != null)
            {
                profile = await ReconcileProfileSubscriptionAsync(accessToken, profile);
                if (!IsCurrentSessionForUser(profile.UserId))
                {
                    ErrorMessage = "Your sign-in session changed. Please try again.";
                    return false;
                }

                CurrentUser = profile;
                IsAuthenticated = true;
                ErrorMessage = null;
                AuthStateChanged?.Invoke(this, EventArgs.Empty);
                return true;
            }

            ErrorMessage = "Failed to load your profile";
            return false;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[AuthService] OAuth callback error: {ex.Message}");
            ErrorMessage = "Sign-in failed. Please try again";
            return false;
        }
        finally
        {
            IsLoading = false;
        }
    }

    /// <summary>
    /// Signs out the current user and clears stored tokens.
    /// </summary>
    public Task SignOutAsync()
    {
        ClearSessionState();
        return Task.CompletedTask;
    }

    /// <summary>
    /// Returns a valid access token for API calls, refreshing it when close to expiry.
    /// </summary>
    public async Task<string?> GetValidAccessTokenAsync(bool reconcileSubscriptionAfterRefresh = true)
    {
        var storedSession = CredentialHelper.LoadSession();
        if (storedSession == null) return null;

        var (accessToken, refreshToken, expiresAt) = storedSession.Value;
        if (DateTimeOffset.UtcNow.AddMinutes(Constants.TokenRefreshBufferMinutes) >= expiresAt)
        {
            var (outcome, refreshed) = await RefreshTokensAsync(refreshToken);
            if (outcome == RefreshOutcome.Rejected)
            {
                ClearSessionState();
            }
            else if (outcome == RefreshOutcome.Success &&
                     reconcileSubscriptionAfterRefresh &&
                     !string.IsNullOrEmpty(refreshed))
            {
                await ReconcileCurrentUserSubscriptionAsync(refreshed);
            }
            return refreshed;
        }

        return accessToken;
    }

    /// <summary>
    /// Refreshes the user profile (word counts, subscription status) from the backend.
    /// </summary>
    public async Task RefreshUserAsync()
    {
        // This path reconciles the freshly fetched profile below, so suppress
        // the otherwise automatic post-token-refresh check to avoid two calls.
        var token = await GetValidAccessTokenAsync(reconcileSubscriptionAfterRefresh: false);
        if (token == null)
        {
            // No usable token right now (possibly just offline) - any definitive
            // rejection has already cleared the session inside the refresh.
            return;
        }

        var profile = await FetchProfileAsync(token);
        if (profile != null)
        {
            profile = await ReconcileProfileSubscriptionAsync(token, profile);
            if (!IsCurrentSessionForUser(profile.UserId)) return;

            CurrentUser = profile;
            IsAuthenticated = true;
            AuthStateChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>
    /// Adds transcribed words to the user's monthly usage counter.
    /// </summary>
    public async Task UpdateWordCountAsync(int wordsToAdd)
    {
        var userAtStart = CurrentUser;
        if (wordsToAdd <= 0 || userAtStart == null) return;

        var token = await GetValidAccessTokenAsync();
        if (token == null || GetJwtSubject(token) != userAtStart.UserId) return;

        try
        {
            var updatedCount = userAtStart.MonthlyWordCount + wordsToAdd;
            var body = new JObject
            {
                ["monthly_word_count"] = updatedCount,
                ["updated_at"] = DateTime.UtcNow.ToString("o")
            };

            using var request = new HttpRequestMessage(
                HttpMethod.Patch,
                $"{BuildConfig.SupabaseUrl}/rest/v1/profiles?user_id=eq.{userAtStart.UserId}&select=*");
            AddSupabaseHeaders(request, token);
            request.Headers.Add("Prefer", "return=representation");
            request.Content = new StringContent(body.ToString(), Encoding.UTF8, "application/json");

            using var response = await _httpClient.SendAsync(request);
            var current = CurrentUser;
            if (response.IsSuccessStatusCode &&
                IsCurrentSessionForUser(userAtStart.UserId) &&
                current?.UserId == userAtStart.UserId)
            {
                var json = await response.Content.ReadAsStringAsync();
                var profiles = JsonConvert.DeserializeObject<UserProfile[]>(json);
                if (profiles is { Length: > 0 } && profiles[0].UserId == userAtStart.UserId)
                {
                    // Updating usage must not replace the last reconciled
                    // RevenueCat status with the profile table's cached value.
                    profiles[0].SubscriptionStatus = current.SubscriptionStatus;
                    CurrentUser = profiles[0];
                }
                else
                {
                    current.MonthlyWordCount = updatedCount;
                }
                OnPropertyChanged(nameof(CurrentUser));
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[AuthService] UpdateWordCount error: {ex.Message}");
        }
    }

    // MARK: - Private Methods

    private void ClearSessionState()
    {
        CredentialHelper.ClearSession();
        CurrentUser = null;
        IsAuthenticated = false;
        AuthStateChanged?.Invoke(this, EventArgs.Empty);
    }

    private enum RefreshOutcome
    {
        Success,
        Rejected,
        NetworkError
    }

    private static void SaveTokens(string accessToken, string refreshToken)
    {
        // Use the JWT's own exp claim; servers can issue shorter-lived tokens
        // than the historical one-hour default.
        var expiresAt = GetJwtExpiry(accessToken) ?? DateTimeOffset.UtcNow.AddMinutes(55);
        CredentialHelper.SaveSession(accessToken, refreshToken, expiresAt);
    }

    private static DateTimeOffset? GetJwtExpiry(string jwt)
    {
        var exp = GetJwtPayload(jwt)?["exp"]?.Value<long>();
        return exp.HasValue ? DateTimeOffset.FromUnixTimeSeconds(exp.Value) : null;
    }

    private async Task<(RefreshOutcome Outcome, string? AccessToken)> RefreshTokensAsync(string refreshToken)
    {
        if (string.IsNullOrEmpty(refreshToken)) return (RefreshOutcome.Rejected, null);

        await _tokenRefreshGate.WaitAsync();
        try
        {
            var sessionAtStart = CredentialHelper.LoadSession();
            if (sessionAtStart == null ||
                !string.Equals(sessionAtStart.Value.RefreshToken, refreshToken, StringComparison.Ordinal))
            {
                // Another sign-in or sign-out replaced this refresh request.
                return (RefreshOutcome.NetworkError, null);
            }

            var expectedUserId = GetJwtSubject(sessionAtStart.Value.AccessToken);
            if (expectedUserId == null) return (RefreshOutcome.Rejected, null);

            using var request = new HttpRequestMessage(
                HttpMethod.Post,
                $"{BuildConfig.SupabaseUrl}/auth/v1/token?grant_type=refresh_token");
            request.Headers.Add("apikey", BuildConfig.SupabaseAnonKey);
            var body = new JObject { ["refresh_token"] = refreshToken };
            request.Content = new StringContent(body.ToString(), Encoding.UTF8, "application/json");

            using var response = await _httpClient.SendAsync(request);
            if (!IsCurrentRefreshSession(refreshToken, expectedUserId.Value))
            {
                // Never let an older request overwrite a newer account session.
                return (RefreshOutcome.NetworkError, null);
            }

            if (!response.IsSuccessStatusCode)
            {
                Debug.WriteLine($"[AuthService] Session refresh failed: {(int)response.StatusCode}");

                // Only a definitive client rejection means the refresh token is
                // dead; a 5xx is the server having a bad day.
                return (int)response.StatusCode < 500
                    ? (RefreshOutcome.Rejected, null)
                    : (RefreshOutcome.NetworkError, null);
            }

            var json = JObject.Parse(await response.Content.ReadAsStringAsync());
            var accessToken = json["access_token"]?.ToString();
            var newRefreshToken = json["refresh_token"]?.ToString() ?? refreshToken;

            if (string.IsNullOrEmpty(accessToken)) return (RefreshOutcome.Rejected, null);
            if (GetJwtSubject(accessToken) != expectedUserId)
            {
                Debug.WriteLine("[AuthService] Session refresh returned an unexpected identity");
                return (RefreshOutcome.Rejected, null);
            }

            var expiresIn = json["expires_in"]?.Value<int>() ?? 3600;
            CredentialHelper.SaveSession(
                accessToken,
                newRefreshToken,
                DateTimeOffset.UtcNow.AddSeconds(expiresIn));

            return (RefreshOutcome.Success, accessToken);
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[AuthService] Refresh error: {ex.Message}");
            return (RefreshOutcome.NetworkError, null);
        }
        finally
        {
            _tokenRefreshGate.Release();
        }
    }

    private async Task<UserProfile?> FetchProfileAsync(string accessToken)
    {
        try
        {
            // First resolve the auth user (id + email) ...
            using var userRequest = new HttpRequestMessage(
                HttpMethod.Get,
                $"{BuildConfig.SupabaseUrl}/auth/v1/user");
            AddSupabaseHeaders(userRequest, accessToken);

            var userResponse = await _httpClient.SendAsync(userRequest);
            if (!userResponse.IsSuccessStatusCode)
            {
                Debug.WriteLine($"[AuthService] Auth user fetch failed: {(int)userResponse.StatusCode}");
                return null;
            }

            var userJson = JObject.Parse(await userResponse.Content.ReadAsStringAsync());
            var userId = userJson["id"]?.ToString();
            var email = userJson["email"]?.ToString() ?? string.Empty;
            if (!Guid.TryParse(userId, out var authenticatedUserId) ||
                GetJwtSubject(accessToken) != authenticatedUserId)
            {
                Debug.WriteLine("[AuthService] Auth user fetch returned an unexpected identity");
                return null;
            }

            // ... then load the profile row with usage and subscription data.
            using var profileRequest = new HttpRequestMessage(
                HttpMethod.Get,
                $"{BuildConfig.SupabaseUrl}/rest/v1/profiles?select=*&user_id=eq.{userId}");
            AddSupabaseHeaders(profileRequest, accessToken);

            var profileResponse = await _httpClient.SendAsync(profileRequest);
            if (profileResponse.IsSuccessStatusCode)
            {
                var json = await profileResponse.Content.ReadAsStringAsync();
                var profiles = JsonConvert.DeserializeObject<UserProfile[]>(json);
                if (profiles is { Length: > 0 } &&
                    profiles[0].UserId == authenticatedUserId)
                {
                    if (string.IsNullOrEmpty(profiles[0].Email))
                    {
                        profiles[0].Email = email;
                    }
                    return profiles[0];
                }
            }

            // No profile row yet - return a minimal profile from auth data.
            return new UserProfile
            {
                UserId = authenticatedUserId,
                Email = email
            };
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[AuthService] Fetch profile error: {ex.Message}");
            return null;
        }
    }

    /// <summary>
    /// Uses the authenticated server reconciliation as the source of truth for
    /// access. A failed lookup leaves the profile's cached status untouched;
    /// a successful "free" response is authoritative and removes paid access.
    /// </summary>
    private async Task<UserProfile> ReconcileProfileSubscriptionAsync(
        string accessToken,
        UserProfile profile)
    {
        var priorUser = CurrentUser;
        var reconciledStatus = await FetchReconciledSubscriptionStatusAsync(
            accessToken,
            profile.UserId);

        if (reconciledStatus != null)
        {
            profile.SubscriptionStatus = reconciledStatus;
        }
        else if (priorUser?.UserId == profile.UserId)
        {
            // During a transient outage, keep the last status shown for this
            // exact account instead of accepting a potentially stale profile row.
            profile.SubscriptionStatus = priorUser.SubscriptionStatus;
        }

        return profile;
    }

    /// <summary>
    /// Reconciles the current account immediately after a token refresh. This
    /// keeps long-running sessions in sync even when no profile refresh follows.
    /// </summary>
    private async Task ReconcileCurrentUserSubscriptionAsync(string accessToken)
    {
        var userAtStart = CurrentUser;
        if (userAtStart == null) return;

        var reconciledStatus = await FetchReconciledSubscriptionStatusAsync(
            accessToken,
            userAtStart.UserId);
        if (reconciledStatus == null || !IsCurrentSessionForUser(userAtStart.UserId)) return;

        var current = CurrentUser;
        if (current?.UserId != userAtStart.UserId ||
            string.Equals(current.SubscriptionStatus, reconciledStatus, StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        current.SubscriptionStatus = reconciledStatus;
        OnPropertyChanged(nameof(CurrentUser));
        AuthStateChanged?.Invoke(this, EventArgs.Empty);
    }

    /// <summary>
    /// Calls the Supabase edge function that resolves RevenueCat, Stripe-imported,
    /// and AppSumo access for the authenticated user. Null means no authoritative
    /// answer was received and callers must preserve their cached state.
    /// </summary>
    private async Task<string?> FetchReconciledSubscriptionStatusAsync(
        string accessToken,
        Guid expectedUserId)
    {
        if (GetJwtSubject(accessToken) != expectedUserId ||
            !IsCurrentSessionForUser(expectedUserId))
        {
            Debug.WriteLine("[AuthService] Subscription check skipped: session identity changed");
            return null;
        }

        await _subscriptionReconciliationGate.WaitAsync();
        try
        {
            // Re-check after waiting because sign-out or a different account
            // may have replaced the session while another lookup was running.
            if (GetJwtSubject(accessToken) != expectedUserId ||
                !IsCurrentSessionForUser(expectedUserId))
            {
                Debug.WriteLine("[AuthService] Subscription check skipped: session identity changed");
                return null;
            }

            using var request = new HttpRequestMessage(
                HttpMethod.Post,
                $"{BuildConfig.SupabaseUrl}/functions/v1/check-subscription");
            AddSupabaseHeaders(request, accessToken);
            request.Content = new StringContent("{}", Encoding.UTF8, "application/json");

            using var response = await _httpClient.SendAsync(request);
            if (!response.IsSuccessStatusCode)
            {
                Debug.WriteLine(
                    $"[AuthService] Subscription check unavailable: {(int)response.StatusCode}");
                return null;
            }

            var json = JObject.Parse(await response.Content.ReadAsStringAsync());
            var status = json["subscription_status"]?.Type == JTokenType.String
                ? json["subscription_status"]!.Value<string>()?.Trim().ToLowerInvariant()
                : null;
            var subscribedToken = json["subscribed"];

            if (subscribedToken?.Type != JTokenType.Boolean ||
                status is not ("free" or "pro" or "lifetime"))
            {
                Debug.WriteLine("[AuthService] Subscription check returned an invalid response");
                return null;
            }

            var subscribed = subscribedToken.Value<bool>();
            if ((status == "free" && subscribed) ||
                (status != "free" && !subscribed))
            {
                Debug.WriteLine("[AuthService] Subscription check returned an inconsistent response");
                return null;
            }

            if (!IsCurrentSessionForUser(expectedUserId))
            {
                Debug.WriteLine("[AuthService] Subscription check ignored: session identity changed");
                return null;
            }

            return status;
        }
        catch (Exception ex)
        {
            // Never log the request, response body, or token. A transient
            // RevenueCat/Supabase failure must not revoke cached paid access.
            Debug.WriteLine($"[AuthService] Subscription check error: {ex.GetType().Name}");
            return null;
        }
        finally
        {
            _subscriptionReconciliationGate.Release();
        }
    }

    private static JObject? GetJwtPayload(string jwt)
    {
        try
        {
            var parts = jwt.Split('.');
            if (parts.Length < 2) return null;

            var payload = parts[1].Replace('-', '+').Replace('_', '/');
            payload = payload.PadRight(payload.Length + (4 - payload.Length % 4) % 4, '=');
            return JObject.Parse(Encoding.UTF8.GetString(Convert.FromBase64String(payload)));
        }
        catch
        {
            return null;
        }
    }

    private static Guid? GetJwtSubject(string jwt)
    {
        var subject = GetJwtPayload(jwt)?["sub"]?.Value<string>();
        return Guid.TryParse(subject, out var userId) ? userId : null;
    }

    private static bool IsCurrentSessionForUser(Guid expectedUserId)
    {
        var session = CredentialHelper.LoadSession();
        return session != null && GetJwtSubject(session.Value.AccessToken) == expectedUserId;
    }

    private static bool IsCurrentRefreshSession(string refreshToken, Guid expectedUserId)
    {
        var session = CredentialHelper.LoadSession();
        return session != null &&
               string.Equals(session.Value.RefreshToken, refreshToken, StringComparison.Ordinal) &&
               GetJwtSubject(session.Value.AccessToken) == expectedUserId;
    }

    private static void AddSupabaseHeaders(HttpRequestMessage request, string accessToken)
    {
        request.Headers.Add("apikey", BuildConfig.SupabaseAnonKey);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
    }
}
