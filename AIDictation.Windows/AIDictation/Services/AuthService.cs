using System;
using System.Diagnostics;
using System.Net.Http;
using System.Net.Http.Headers;
using System.Text;
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
                accessToken = await RefreshTokensAsync(refreshToken) ?? string.Empty;
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
                accessToken = await RefreshTokensAsync(refreshToken) ?? string.Empty;
                profile = string.IsNullOrEmpty(accessToken) ? null : await FetchProfileAsync(accessToken);
            }

            if (profile != null)
            {
                CurrentUser = profile;
                IsAuthenticated = true;
                AuthStateChanged?.Invoke(this, EventArgs.Empty);
            }
            else
            {
                ClearSessionState();
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[AuthService] Initialize error: {ex.Message}");
            ErrorMessage = "Failed to restore session";
            ClearSessionState();
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
    /// Opens the Stripe upgrade page, pre-filled with the signed-in user's email.
    /// </summary>
    public void OpenUpgrade()
    {
        var link = BuildConfig.StripePaymentLink;
        if (string.IsNullOrWhiteSpace(link))
        {
            return;
        }

        if (CurrentUser == null)
        {
            OpenLogin();
            return;
        }

        var separator = link.Contains('?') ? "&" : "?";
        var url = $"{link}{separator}prefilled_email={Uri.EscapeDataString(CurrentUser.Email)}";
        Process.Start(new ProcessStartInfo { FileName = url, UseShellExecute = true });
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
    public async Task<string?> GetValidAccessTokenAsync()
    {
        var storedSession = CredentialHelper.LoadSession();
        if (storedSession == null) return null;

        var (accessToken, refreshToken, expiresAt) = storedSession.Value;
        if (DateTimeOffset.UtcNow.AddMinutes(Constants.TokenRefreshBufferMinutes) >= expiresAt)
        {
            return await RefreshTokensAsync(refreshToken);
        }

        return accessToken;
    }

    /// <summary>
    /// Refreshes the user profile (word counts, subscription status) from the backend.
    /// </summary>
    public async Task RefreshUserAsync()
    {
        var token = await GetValidAccessTokenAsync();
        if (token == null)
        {
            ClearSessionState();
            return;
        }

        var profile = await FetchProfileAsync(token);
        if (profile != null)
        {
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
        if (wordsToAdd <= 0 || CurrentUser == null) return;

        var token = await GetValidAccessTokenAsync();
        if (token == null) return;

        try
        {
            var updatedCount = CurrentUser.MonthlyWordCount + wordsToAdd;
            var body = new JObject
            {
                ["monthly_word_count"] = updatedCount,
                ["updated_at"] = DateTime.UtcNow.ToString("o")
            };

            using var request = new HttpRequestMessage(
                HttpMethod.Patch,
                $"{BuildConfig.SupabaseUrl}/rest/v1/profiles?user_id=eq.{CurrentUser.UserId}&select=*");
            AddSupabaseHeaders(request, token);
            request.Headers.Add("Prefer", "return=representation");
            request.Content = new StringContent(body.ToString(), Encoding.UTF8, "application/json");

            var response = await _httpClient.SendAsync(request);
            if (response.IsSuccessStatusCode)
            {
                var json = await response.Content.ReadAsStringAsync();
                var profiles = JsonConvert.DeserializeObject<UserProfile[]>(json);
                if (profiles is { Length: > 0 })
                {
                    CurrentUser = profiles[0];
                }
                else
                {
                    CurrentUser.MonthlyWordCount = updatedCount;
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

    private static void SaveTokens(string accessToken, string refreshToken)
    {
        // Access tokens from GoTrue last one hour; the exact expiry is refreshed lazily.
        var expiresAt = DateTimeOffset.UtcNow.AddMinutes(55);
        CredentialHelper.SaveSession(accessToken, refreshToken, expiresAt);
    }

    private async Task<string?> RefreshTokensAsync(string refreshToken)
    {
        if (string.IsNullOrEmpty(refreshToken)) return null;

        try
        {
            using var request = new HttpRequestMessage(
                HttpMethod.Post,
                $"{BuildConfig.SupabaseUrl}/auth/v1/token?grant_type=refresh_token");
            request.Headers.Add("apikey", BuildConfig.SupabaseAnonKey);
            var body = new JObject { ["refresh_token"] = refreshToken };
            request.Content = new StringContent(body.ToString(), Encoding.UTF8, "application/json");

            var response = await _httpClient.SendAsync(request);
            if (!response.IsSuccessStatusCode)
            {
                Debug.WriteLine($"[AuthService] Session refresh failed: {(int)response.StatusCode}");
                return null;
            }

            var json = JObject.Parse(await response.Content.ReadAsStringAsync());
            var accessToken = json["access_token"]?.ToString();
            var newRefreshToken = json["refresh_token"]?.ToString() ?? refreshToken;

            if (string.IsNullOrEmpty(accessToken)) return null;

            var expiresIn = json["expires_in"]?.Value<int>() ?? 3600;
            CredentialHelper.SaveSession(
                accessToken,
                newRefreshToken,
                DateTimeOffset.UtcNow.AddSeconds(expiresIn));

            return accessToken;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[AuthService] Refresh error: {ex.Message}");
            return null;
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
            if (string.IsNullOrEmpty(userId)) return null;

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
                if (profiles is { Length: > 0 })
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
                UserId = Guid.Parse(userId),
                Email = email
            };
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[AuthService] Fetch profile error: {ex.Message}");
            return null;
        }
    }

    private static void AddSupabaseHeaders(HttpRequestMessage request, string accessToken)
    {
        request.Headers.Add("apikey", BuildConfig.SupabaseAnonKey);
        request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", accessToken);
    }
}
