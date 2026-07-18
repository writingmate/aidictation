using Xunit;

namespace AIDictation.Services;

public sealed class RevenueCatCheckoutLinkTests
{
    [Theory]
    [InlineData("https://pay.rev.cat/production_token")]
    [InlineData("HTTPS://PAY.REV.CAT/production_token")]
    public void TryParseCanonicalBaseUri_AcceptsProductionPurchaseLinkShape(string configuredLink)
    {
        var succeeded = RevenueCatCheckoutLink.TryParseCanonicalBaseUri(
            configuredLink,
            out var purchaseLink);

        Assert.True(succeeded);
        Assert.Equal("https://pay.rev.cat/production_token", purchaseLink?.AbsoluteUri);
    }

    [Theory]
    [InlineData("")]
    [InlineData("pay.rev.cat/production_token")]
    [InlineData("http://pay.rev.cat/production_token")]
    [InlineData("https://example.com/production_token")]
    [InlineData("https://checkout.pay.rev.cat/production_token")]
    [InlineData("https://pay.rev.cat:443/production_token")]
    [InlineData("https://pay.rev.cat:444/production_token")]
    [InlineData("https://user@pay.rev.cat/production_token")]
    [InlineData("https://pay.rev.cat/")]
    [InlineData("https://pay.rev.cat/production_token/")]
    [InlineData("https://pay.rev.cat/production_token/extra")]
    [InlineData("https://pay.rev.cat/production_token?package_id=monthly")]
    [InlineData("https://pay.rev.cat/production_token#checkout")]
    [InlineData("https://pay.rev.cat/production%2Ftoken")]
    [InlineData("https://pay.rev.cat/production%2ftoken")]
    [InlineData("https://pay.rev.cat/production%5Ctoken")]
    [InlineData("https://pay.rev.cat/production%5ctoken")]
    [InlineData("https://pay.rev.cat/.")]
    [InlineData("https://pay.rev.cat/..")]
    [InlineData("https://pay.rev.cat/%2e")]
    [InlineData("https://pay.rev.cat/%2e%2e")]
    public void TryParseCanonicalBaseUri_RejectsNonCanonicalPurchaseLinks(string configuredLink)
    {
        Assert.False(RevenueCatCheckoutLink.TryParseCanonicalBaseUri(configuredLink, out _));
    }

    [Fact]
    public void TryCreateCheckoutUri_AppendsLowercaseSignedInCustomerIdentity()
    {
        var succeeded = RevenueCatCheckoutLink.TryCreateCheckoutUri(
            "https://pay.rev.cat/production_token",
            Guid.Parse("A5D1929E-27CC-4C17-84A6-D815D031B933"),
            "person@example.com",
            out var checkoutUri);

        Assert.True(succeeded);
        Assert.Equal(
            "https://pay.rev.cat/production_token/a5d1929e-27cc-4c17-84a6-d815d031b933?email=person%40example.com",
            checkoutUri?.AbsoluteUri);
    }

    [Fact]
    public void TryCreateCheckoutUri_EscapesEmailAsOneQueryValue()
    {
        var succeeded = RevenueCatCheckoutLink.TryCreateCheckoutUri(
            "https://pay.rev.cat/production_token",
            Guid.Parse("a5d1929e-27cc-4c17-84a6-d815d031b933"),
            "person+desktop@example.com&package_id=annual",
            out var checkoutUri);

        Assert.True(succeeded);
        Assert.Equal(
            "?email=person%2Bdesktop%40example.com%26package_id%3Dannual",
            checkoutUri?.Query);
    }
}
