using System;

namespace AIDictation.Services;

/// <summary>
/// Validates and personalizes the hosted checkout link without opening a browser.
/// Keeping this logic free of Windows APIs lets release checks exercise the same
/// URL contract as the desktop app.
/// </summary>
internal static class RevenueCatCheckoutLink
{
    internal static bool TryParseCanonicalBaseUri(string configuredLink, out Uri? purchaseLink)
    {
        purchaseLink = null;

        if (!Uri.TryCreate(configuredLink, UriKind.Absolute, out var candidate))
        {
            return false;
        }

        var escapedPath = candidate.GetComponents(UriComponents.Path, UriFormat.UriEscaped);
        var pathSegments = candidate.AbsolutePath.Split('/', StringSplitOptions.None);
        if (candidate.Scheme != Uri.UriSchemeHttps ||
            !candidate.Host.Equals("pay.rev.cat", StringComparison.OrdinalIgnoreCase) ||
            !candidate.IsDefaultPort ||
            !string.Equals(configuredLink, candidate.AbsoluteUri, StringComparison.OrdinalIgnoreCase) ||
            !string.IsNullOrEmpty(candidate.UserInfo) ||
            !string.IsNullOrEmpty(candidate.Query) ||
            !string.IsNullOrEmpty(candidate.Fragment) ||
            escapedPath.Contains("%2f", StringComparison.OrdinalIgnoreCase) ||
            escapedPath.Contains("%5c", StringComparison.OrdinalIgnoreCase) ||
            pathSegments.Length != 2 ||
            !string.IsNullOrEmpty(pathSegments[0]) ||
            string.IsNullOrEmpty(pathSegments[1]))
        {
            return false;
        }

        purchaseLink = candidate;
        return true;
    }

    internal static bool TryCreateCheckoutUri(
        string configuredLink,
        Guid userId,
        string email,
        out Uri? checkoutUri)
    {
        checkoutUri = null;

        if (!TryParseCanonicalBaseUri(configuredLink, out var purchaseLink) || purchaseLink == null)
        {
            return false;
        }

        var urlString =
            $"{purchaseLink.AbsoluteUri.TrimEnd('/')}/{Uri.EscapeDataString(userId.ToString().ToLowerInvariant())}" +
            $"?email={Uri.EscapeDataString(email)}";

        if (!Uri.TryCreate(urlString, UriKind.Absolute, out var candidate) ||
            candidate.Scheme != Uri.UriSchemeHttps)
        {
            return false;
        }

        checkoutUri = candidate;
        return true;
    }
}
