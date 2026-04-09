using System;
using System.Diagnostics;
using System.Net;
using System.Threading;
using System.Threading.Tasks;
using AIDictation.Helpers;
using AIDictation.Models;
using AppUser = AIDictation.Models.User;
using CommunityToolkit.Mvvm.ComponentModel;
using Supabase;
using Supabase.Gotrue;
using Supabase.Gotrue.Interfaces;
using static Supabase.Gotrue.Constants;

namespace AIDictation.Services;

/// <summary>
/// Manages authentication with Supabase including email/password and OAuth login,
/// session persistence, and token refresh
/// </summary>
public partial class AuthService : ObservableObject
{
    // MARK: - Constants

    private static class Config
    {
        // TODO: Replace with actual values or load from environment
        public const string SupabaseUrl = "YOUR_SUPABASE_URL";
        public const string SupabaseKey = "YOUR_SUPABASE_ANON_KEY";
        public const string OAuthRedirectScheme = "aidictation";
        public const string OAuthCallbackPath = "auth/callback";
        public const int TokenRefreshBufferMinutes = 5;
        public const int OAuthListenerPort = 8234;
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
    private AppUser? _currentUser;

    [ObservableProperty]
    private string? _errorMessage;

    // MARK: - Private Properties

    private Supabase.Client? _supabaseClient;
    private HttpListener? _oauthListener;
    private CancellationTokenSource? _oauthCts;

    // MARK: - Events

    public event EventHandler? AuthStateChanged;

    // MARK: - Initialization

    private AuthService()
    {
        InitializeSupabase();
    }

    private void InitializeSupabase()
    {
        var url = Environment.GetEnvironmentVariable("SUPABASE_URL") ?? Config.SupabaseUrl;
        var key = Environment.GetEnvironmentVariable("SUPABASE_KEY") ?? Config.SupabaseKey;

        var options = new SupabaseOptions
        {
            AutoRefreshToken = true,
            AutoConnectRealtime = false
        };

        _supabaseClient = new Supabase.Client(url, key, options);
        
        // Subscribe to auth state changes
        _supabaseClient.Auth.AddStateChangedListener(OnAuthStateChanged);
    }

    // MARK: - Public API

    /// <summary>
    /// Initializes authentication on app startup - loads stored session and validates it
    /// </summary>
    public async Task InitializeAsync()
    {
        IsLoading = true;
        ErrorMessage = null;

        try
        {
            var storedSession = CredentialHelper.LoadSession();
            if (storedSession == null)
            {
                Debug.WriteLine("[AuthService] No stored session found");
                IsAuthenticated = false;
                return;
            }

            var (accessToken, refreshToken, expiresAt) = storedSession.Value;

            // Check if token needs refresh
            if (DateTimeOffset.UtcNow.AddMinutes(Config.TokenRefreshBufferMinutes) >= expiresAt)
            {
                Debug.WriteLine("[AuthService] Token expired or expiring soon, refreshing...");
                await RefreshSessionAsync(refreshToken);
            }
            else
            {
                // Set the session directly
                var session = await _supabaseClient!.Auth.SetSession(accessToken, refreshToken);
                if (session != null)
                {
                    await OnSessionEstablished(session);
                }
                else
                {
                    Debug.WriteLine("[AuthService] Failed to restore session, attempting refresh");
                    await RefreshSessionAsync(refreshToken);
                }
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[AuthService] Initialize error: {ex.Message}");
            ErrorMessage = "Failed to restore session";
            CredentialHelper.ClearSession();
            IsAuthenticated = false;
        }
        finally
        {
            IsLoading = false;
        }
    }

    /// <summary>
    /// Signs in with email and password
    /// </summary>
    public async Task<bool> SignInWithEmailAsync(string email, string password)
    {
        IsLoading = true;
        ErrorMessage = null;

        try
        {
            var session = await _supabaseClient!.Auth.SignIn(email, password);
            if (session != null)
            {
                await OnSessionEstablished(session);
                return true;
            }

            ErrorMessage = "Invalid email or password";
            return false;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[AuthService] SignIn error: {ex.Message}");
            ErrorMessage = GetUserFriendlyError(ex);
            return false;
        }
        finally
        {
            IsLoading = false;
        }
    }

    /// <summary>
    /// Signs up with email and password
    /// </summary>
    public async Task<bool> SignUpWithEmailAsync(string email, string password)
    {
        IsLoading = true;
        ErrorMessage = null;

        try
        {
            var session = await _supabaseClient!.Auth.SignUp(email, password);
            if (session != null)
            {
                await OnSessionEstablished(session);
                return true;
            }

            // Sign up may return null if email confirmation is required
            ErrorMessage = "Please check your email to confirm your account";
            return false;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[AuthService] SignUp error: {ex.Message}");
            ErrorMessage = GetUserFriendlyError(ex);
            return false;
        }
        finally
        {
            IsLoading = false;
        }
    }

    /// <summary>
    /// Signs in with Google OAuth
    /// </summary>
    public async Task<bool> SignInWithGoogleAsync()
    {
        IsLoading = true;
        ErrorMessage = null;

        try
        {
            // Start local HTTP listener for OAuth callback
            var redirectUri = await StartOAuthListenerAsync();
            
            // Get OAuth URL from Supabase
            var signInUrl = await _supabaseClient!.Auth.SignIn(
                Provider.Google,
                new SignInOptions
                {
                    RedirectTo = redirectUri
                }
            );

            if (signInUrl == null)
            {
                ErrorMessage = "Failed to start Google sign-in";
                return false;
            }

            // Open browser for authentication
            Process.Start(new ProcessStartInfo
            {
                FileName = signInUrl.Uri?.ToString(),
                UseShellExecute = true
            });

            // Wait for callback
            var result = await WaitForOAuthCallbackAsync();
            return result;
        }
        catch (OperationCanceledException)
        {
            Debug.WriteLine("[AuthService] OAuth cancelled");
            ErrorMessage = "Sign-in was cancelled";
            return false;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[AuthService] Google SignIn error: {ex.Message}");
            ErrorMessage = GetUserFriendlyError(ex);
            return false;
        }
        finally
        {
            StopOAuthListener();
            IsLoading = false;
        }
    }

    /// <summary>
    /// Handles OAuth callback from custom URL scheme (aidictation://auth/callback)
    /// </summary>
    public async Task<bool> HandleOAuthCallbackAsync(Uri callbackUri)
    {
        try
        {
            // Parse the callback URL for tokens
            var query = System.Web.HttpUtility.ParseQueryString(callbackUri.Query);
            var fragment = callbackUri.Fragment.TrimStart('#');
            var fragmentParams = System.Web.HttpUtility.ParseQueryString(fragment);

            var accessToken = fragmentParams["access_token"] ?? query["access_token"];
            var refreshToken = fragmentParams["refresh_token"] ?? query["refresh_token"];

            if (string.IsNullOrEmpty(accessToken) || string.IsNullOrEmpty(refreshToken))
            {
                ErrorMessage = "Invalid callback - missing tokens";
                return false;
            }

            var session = await _supabaseClient!.Auth.SetSession(accessToken, refreshToken);
            if (session != null)
            {
                await OnSessionEstablished(session);
                return true;
            }

            ErrorMessage = "Failed to establish session";
            return false;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[AuthService] OAuth callback error: {ex.Message}");
            ErrorMessage = GetUserFriendlyError(ex);
            return false;
        }
    }

    /// <summary>
    /// Signs out the current user
    /// </summary>
    public async Task SignOutAsync()
    {
        IsLoading = true;

        try
        {
            await _supabaseClient!.Auth.SignOut();
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[AuthService] SignOut error: {ex.Message}");
        }
        finally
        {
            CredentialHelper.ClearSession();
            CurrentUser = null;
            IsAuthenticated = false;
            IsLoading = false;
            AuthStateChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    /// <summary>
    /// Sends password reset email
    /// </summary>
    public async Task<bool> SendPasswordResetAsync(string email)
    {
        IsLoading = true;
        ErrorMessage = null;

        try
        {
            await _supabaseClient!.Auth.ResetPasswordForEmail(email);
            return true;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[AuthService] Password reset error: {ex.Message}");
            ErrorMessage = GetUserFriendlyError(ex);
            return false;
        }
        finally
        {
            IsLoading = false;
        }
    }

    /// <summary>
    /// Refreshes the current session
    /// </summary>
    public async Task<bool> RefreshSessionAsync()
    {
        var storedSession = CredentialHelper.LoadSession();
        if (storedSession == null) return false;

        return await RefreshSessionAsync(storedSession.Value.RefreshToken);
    }

    /// <summary>
    /// Gets the current access token for API calls
    /// </summary>
    public string? GetAccessToken()
    {
        return _supabaseClient?.Auth.CurrentSession?.AccessToken;
    }

    /// <summary>
    /// Gets the Supabase client for direct database access
    /// </summary>
    public Supabase.Client? GetSupabaseClient() => _supabaseClient;

    // MARK: - Private Methods

    private async Task RefreshSessionAsync(string refreshToken)
    {
        try
        {
            var session = await _supabaseClient!.Auth.RefreshSession();
            if (session != null)
            {
                await OnSessionEstablished(session);
            }
            else
            {
                Debug.WriteLine("[AuthService] Session refresh returned null");
                CredentialHelper.ClearSession();
                IsAuthenticated = false;
            }
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[AuthService] Refresh error: {ex.Message}");
            CredentialHelper.ClearSession();
            IsAuthenticated = false;
            throw;
        }
    }

    private async Task OnSessionEstablished(Session session)
    {
        // Save tokens to credential manager
        if (!string.IsNullOrEmpty(session.AccessToken) && !string.IsNullOrEmpty(session.RefreshToken))
        {
            var expiresAt = DateTimeOffset.UtcNow.AddSeconds(session.ExpiresIn);
            CredentialHelper.SaveSession(session.AccessToken, session.RefreshToken, expiresAt);
        }

        // Fetch user profile from database
        await FetchUserProfileAsync(session.User?.Id);

        IsAuthenticated = true;
        AuthStateChanged?.Invoke(this, EventArgs.Empty);
    }

    private async Task FetchUserProfileAsync(string? userId)
    {
        if (string.IsNullOrEmpty(userId) || _supabaseClient == null)
        {
            CurrentUser = null;
            return;
        }

        try
        {
            var response = await _supabaseClient
                .From<AppUser>()
                .Where(u => u.UserId == Guid.Parse(userId))
                .Single();

            CurrentUser = response;
        }
        catch (Exception ex)
        {
            Debug.WriteLine($"[AuthService] Fetch user profile error: {ex.Message}");
            // Create a minimal user object from auth data
            CurrentUser = new AppUser
            {
                UserId = Guid.Parse(userId),
                Email = _supabaseClient.Auth.CurrentUser?.Email ?? ""
            };
        }
    }

    private void OnAuthStateChanged(IGotrueClient<Supabase.Gotrue.User, Session> sender, AuthState state)
    {
        Debug.WriteLine($"[AuthService] Auth state changed: {state}");
        
        switch (state)
        {
            case AuthState.SignedIn:
                IsAuthenticated = true;
                break;
            case AuthState.SignedOut:
                IsAuthenticated = false;
                CurrentUser = null;
                CredentialHelper.ClearSession();
                break;
            case AuthState.TokenRefreshed:
                var session = _supabaseClient?.Auth.CurrentSession;
                if (session != null && !string.IsNullOrEmpty(session.AccessToken))
                {
                    var expiresAt = DateTimeOffset.UtcNow.AddSeconds(session.ExpiresIn);
                    CredentialHelper.SaveSession(session.AccessToken, session.RefreshToken!, expiresAt);
                }
                break;
        }

        AuthStateChanged?.Invoke(this, EventArgs.Empty);
    }

    private async Task<string> StartOAuthListenerAsync()
    {
        StopOAuthListener();
        
        _oauthCts = new CancellationTokenSource(TimeSpan.FromMinutes(5));
        _oauthListener = new HttpListener();
        
        var redirectUri = $"http://localhost:{Config.OAuthListenerPort}/";
        _oauthListener.Prefixes.Add(redirectUri);
        _oauthListener.Start();

        return redirectUri;
    }

    private async Task<bool> WaitForOAuthCallbackAsync()
    {
        if (_oauthListener == null || _oauthCts == null)
            return false;

        try
        {
            var context = await _oauthListener.GetContextAsync().WaitAsync(_oauthCts.Token);
            var request = context.Request;
            var response = context.Response;

            // Parse tokens from the callback
            var query = request.QueryString;
            var accessToken = query["access_token"];
            var refreshToken = query["refresh_token"];

            // If tokens are in fragment, we need to handle it client-side
            // Send HTML page that extracts fragment and posts back
            if (string.IsNullOrEmpty(accessToken))
            {
                var html = GetOAuthCallbackHtml();
                var buffer = System.Text.Encoding.UTF8.GetBytes(html);
                response.ContentType = "text/html";
                response.ContentLength64 = buffer.Length;
                await response.OutputStream.WriteAsync(buffer);
                response.Close();

                // Wait for second request with tokens
                context = await _oauthListener.GetContextAsync().WaitAsync(_oauthCts.Token);
                request = context.Request;
                response = context.Response;
                query = request.QueryString;
                accessToken = query["access_token"];
                refreshToken = query["refresh_token"];
            }

            // Send success response
            var successHtml = "<html><body><h1>Sign in successful!</h1><p>You can close this window.</p><script>window.close();</script></body></html>";
            var successBuffer = System.Text.Encoding.UTF8.GetBytes(successHtml);
            response.ContentType = "text/html";
            response.ContentLength64 = successBuffer.Length;
            await response.OutputStream.WriteAsync(successBuffer);
            response.Close();

            if (!string.IsNullOrEmpty(accessToken) && !string.IsNullOrEmpty(refreshToken))
            {
                var session = await _supabaseClient!.Auth.SetSession(accessToken, refreshToken);
                if (session != null)
                {
                    await OnSessionEstablished(session);
                    return true;
                }
            }

            return false;
        }
        catch (OperationCanceledException)
        {
            return false;
        }
    }

    private void StopOAuthListener()
    {
        _oauthCts?.Cancel();
        _oauthCts?.Dispose();
        _oauthCts = null;

        try
        {
            _oauthListener?.Stop();
            _oauthListener?.Close();
        }
        catch { }
        
        _oauthListener = null;
    }

    private static string GetOAuthCallbackHtml()
    {
        return """
            <!DOCTYPE html>
            <html>
            <head><title>Signing in...</title></head>
            <body>
                <h1>Completing sign in...</h1>
                <script>
                    const hash = window.location.hash.substring(1);
                    if (hash) {
                        const params = new URLSearchParams(hash);
                        const accessToken = params.get('access_token');
                        const refreshToken = params.get('refresh_token');
                        if (accessToken && refreshToken) {
                            window.location.href = window.location.pathname + 
                                '?access_token=' + encodeURIComponent(accessToken) + 
                                '&refresh_token=' + encodeURIComponent(refreshToken);
                        }
                    }
                </script>
            </body>
            </html>
            """;
    }

    private static string GetUserFriendlyError(Exception ex)
    {
        var message = ex.Message.ToLowerInvariant();

        if (message.Contains("invalid login credentials") || message.Contains("invalid password"))
            return "Invalid email or password";
        if (message.Contains("email not confirmed"))
            return "Please confirm your email address";
        if (message.Contains("user already registered"))
            return "An account with this email already exists";
        if (message.Contains("rate limit"))
            return "Too many attempts. Please try again later";
        if (message.Contains("network") || message.Contains("connection"))
            return "Network error. Please check your connection";

        return "An error occurred. Please try again";
    }
}
