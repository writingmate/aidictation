using System;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using CredentialManagement;

namespace AIDictation.Helpers;

/// <summary>
/// Helper class for storing and retrieving credentials from Windows Credential Manager,
/// with a DPAPI-protected file fallback for secrets that Credential Manager rejects
/// (CredWrite caps generic blobs at ~2.5 KB; Supabase JWTs can exceed that).
/// </summary>
public static class CredentialHelper
{
    // MARK: - Constants

    private const string CredentialTarget = "AIDictation_Supabase_Session";
    private const string AccessTokenKey = "AccessToken";
    private const string RefreshTokenKey = "RefreshToken";
    private const string ExpiresAtKey = "ExpiresAt";

    private static string FallbackDirectory => Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "AIDictation");

    // MARK: - Public API

    /// <summary>
    /// Saves session tokens to Windows Credential Manager
    /// </summary>
    public static void SaveSession(string accessToken, string refreshToken, DateTimeOffset expiresAt)
    {
        SaveCredential($"{CredentialTarget}_{AccessTokenKey}", accessToken);
        SaveCredential($"{CredentialTarget}_{RefreshTokenKey}", refreshToken);
        SaveCredential($"{CredentialTarget}_{ExpiresAtKey}", expiresAt.ToUnixTimeSeconds().ToString());
    }

    /// <summary>
    /// Retrieves session tokens from Windows Credential Manager
    /// </summary>
    /// <returns>Tuple of (accessToken, refreshToken, expiresAt) or null if not found</returns>
    public static (string AccessToken, string RefreshToken, DateTimeOffset ExpiresAt)? LoadSession()
    {
        var accessToken = LoadCredential($"{CredentialTarget}_{AccessTokenKey}");
        var refreshToken = LoadCredential($"{CredentialTarget}_{RefreshTokenKey}");
        var expiresAtStr = LoadCredential($"{CredentialTarget}_{ExpiresAtKey}");

        if (string.IsNullOrEmpty(accessToken) ||
            string.IsNullOrEmpty(refreshToken) ||
            string.IsNullOrEmpty(expiresAtStr))
        {
            return null;
        }

        if (!long.TryParse(expiresAtStr, out var expiresAtUnix))
        {
            return null;
        }

        var expiresAt = DateTimeOffset.FromUnixTimeSeconds(expiresAtUnix);
        return (accessToken, refreshToken, expiresAt);
    }

    /// <summary>
    /// Clears all stored session credentials
    /// </summary>
    public static void ClearSession()
    {
        DeleteCredential($"{CredentialTarget}_{AccessTokenKey}");
        DeleteCredential($"{CredentialTarget}_{RefreshTokenKey}");
        DeleteCredential($"{CredentialTarget}_{ExpiresAtKey}");
    }

    /// <summary>
    /// Checks if a session exists in storage
    /// </summary>
    public static bool HasStoredSession()
    {
        var accessToken = LoadCredential($"{CredentialTarget}_{AccessTokenKey}");
        return !string.IsNullOrEmpty(accessToken);
    }

    // MARK: - Private Methods

    private static void SaveCredential(string target, string secret)
    {
        try
        {
            using var credential = new Credential
            {
                Target = target,
                Username = "AIDictation",
                Password = secret,
                PersistanceType = PersistanceType.LocalComputer
            };
            if (credential.Save())
            {
                // Don't let a stale fallback file shadow the fresh value.
                DeleteFallbackFile(target);
                return;
            }
        }
        catch
        {
            // Fall through to the DPAPI file fallback below.
        }

        SaveFallbackFile(target, secret);
    }

    private static string? LoadCredential(string target)
    {
        try
        {
            using var credential = new Credential { Target = target };
            if (credential.Load())
            {
                return credential.Password;
            }
        }
        catch
        {
            // Fall through to the fallback file.
        }

        return LoadFallbackFile(target);
    }

    private static void DeleteCredential(string target)
    {
        try
        {
            using var credential = new Credential { Target = target };
            credential.Delete();
        }
        catch
        {
            // Nothing to delete or access denied.
        }

        DeleteFallbackFile(target);
    }

    // MARK: - DPAPI File Fallback

    private static string FallbackPath(string target) => Path.Combine(FallbackDirectory, target + ".bin");

    private static void SaveFallbackFile(string target, string secret)
    {
        try
        {
            Directory.CreateDirectory(FallbackDirectory);
            var protectedBytes = ProtectedData.Protect(
                Encoding.UTF8.GetBytes(secret),
                optionalEntropy: null,
                scope: DataProtectionScope.CurrentUser);
            File.WriteAllBytes(FallbackPath(target), protectedBytes);
        }
        catch
        {
            // Secret storage failed entirely; the user will be asked to sign in again.
        }
    }

    private static string? LoadFallbackFile(string target)
    {
        try
        {
            var path = FallbackPath(target);
            if (!File.Exists(path)) return null;

            var bytes = ProtectedData.Unprotect(
                File.ReadAllBytes(path),
                optionalEntropy: null,
                scope: DataProtectionScope.CurrentUser);
            return Encoding.UTF8.GetString(bytes);
        }
        catch
        {
            return null;
        }
    }

    private static void DeleteFallbackFile(string target)
    {
        try
        {
            var path = FallbackPath(target);
            if (File.Exists(path))
            {
                File.Delete(path);
            }
        }
        catch
        {
            // Best effort.
        }
    }
}
