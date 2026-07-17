# RevenueCat migration

The apps use one RevenueCat customer identity across macOS, Android, and Windows: the lowercase Supabase `user_id` UUID. The entitlement identifier defaults to `pro`.

## RevenueCat dashboard

1. Create Apple, Google Play, and Web apps in one RevenueCat project.
2. Import the existing products from App Store Connect, Google Play, and Stripe Billing (or RevenueCat Billing).
3. Attach every paid product, including the lifetime product, to the `pro` entitlement.
4. Create a current offering. Use the standard `$rc_monthly`, `$rc_annual`, and `$rc_lifetime` packages where applicable.
5. Create a Web Purchase Link for macOS and Windows and copy its production URL template (`https://pay.rev.cat/...`).
6. Add a webhook pointing to `https://<project-ref>.supabase.co/functions/v1/revenuecat-webhook`. Set its authorization header to the exact value stored in `REVENUECAT_WEBHOOK_AUTHORIZATION`.

## Build configuration

- iOS: the public Apple SDK key (`REVENUECAT_APPLE_API_KEY`, beginning with `appl_`) and optional `REVENUECAT_ENTITLEMENT_ID` (default `pro`).
- macOS and Windows: `REVENUECAT_WEB_PURCHASE_LINK` for the production hosted purchase page (`https://pay.rev.cat/...`, without query or fragment). The direct-distribution macOS build does not initiate App Store purchases.
- Android: `REVENUECAT_GOOGLE_API_KEY` and optional `REVENUECAT_ENTITLEMENT_ID`.

These are public platform SDK keys or hosted purchase URLs. Never put a RevenueCat secret API key in an app build.

## Backend deployment

Apply `website/supabase/migrations/202607160001_revenuecat_subscription_sync.sql`, then deploy the functions from the `website` project. Keep JWT verification disabled only for `revenuecat-webhook` because RevenueCat authenticates with the configured authorization header.

Set these function secrets:

```text
REVENUECAT_WEBHOOK_AUTHORIZATION=<a long random authorization value>
REVENUECAT_ENTITLEMENT_ID=pro
REVENUECAT_SECRET_API_KEY=<RevenueCat secret API key with customer read/write access>
REVENUECAT_STRIPE_API_KEY=<public API key for the connected RevenueCat Stripe app>
```

Supabase supplies `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` to deployed Edge Functions.

## Existing subscribers

Import or connect the existing Stripe subscriptions in RevenueCat before switching the Windows purchase link. Keep the existing `subscription_status` values during the rollout; RevenueCat webhooks will update them on the next lifecycle event. For an immediate cutover, backfill existing subscribers through RevenueCat's subscriber import process and reconcile their current entitlement state before removing the old Stripe webhook.
