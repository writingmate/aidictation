# RevenueCat migration

The apps use one RevenueCat customer identity across macOS, Android, and Windows: the lowercase Supabase `user_id` UUID. The entitlement identifier defaults to `pro`.

## RevenueCat dashboard

1. Create Apple, Google Play, and Web apps in one RevenueCat project.
2. Import the existing products from App Store Connect, Google Play, and Stripe Billing (or RevenueCat Billing).
3. Attach every paid product, including the lifetime product, to the exact `pro` entitlement. Production release checks reject any other entitlement identifier.
4. Create a current offering with these exact mappings: `$rc_monthly` to the store monthly product and Stripe lookup key `monthly`, `$rc_annual` to the store yearly product and Stripe lookup key `yearly`, and `$rc_lifetime` to the non-expiring store product and Stripe lookup key `lifetime`. Apple and Web use all three packages; the current Android client purchases `$rc_monthly` only.
5. Create a Web Purchase Link for macOS and Windows and copy its production URL (`https://pay.rev.cat/<production-token>`).
6. Add a webhook pointing to `https://<project-ref>.supabase.co/functions/v1/revenuecat-webhook`. Set its authorization header to the exact value stored in `REVENUECAT_WEBHOOK_AUTHORIZATION`.

## Build configuration

- iOS: the public Apple SDK key (`REVENUECAT_APPLE_API_KEY`, beginning with `appl_`) and `REVENUECAT_ENTITLEMENT_ID=pro`.
- macOS and Windows: `REVENUECAT_WEB_PURCHASE_LINK` for the production hosted purchase page (`https://pay.rev.cat/<production-token>`, with exactly one path segment and no query or fragment). The apps append the signed-in user's ID; the direct-distribution macOS build does not initiate App Store purchases.
- Android: `REVENUECAT_GOOGLE_API_KEY` and `REVENUECAT_ENTITLEMENT_ID=pro`.

These are public platform SDK keys or hosted purchase URLs. Never put a RevenueCat secret API key in an app build.

## Backend deployment

Deploy the backend before releasing any updated native client:

1. Apply `supabase/migrations/20260718150723_bind_profile_mutations_to_session.sql` to the shared Supabase project. This adds the session-bound profile RPCs used by the Apple and Android apps while keeping the previous referral RPCs available for older clients.
2. Apply `website/supabase/migrations/202607160001_revenuecat_subscription_sync.sql` to the same project.
3. Deploy the functions from the `website` project.
4. Run `python3 scripts/test_session_bound_profile_mutations.py`, verify RevenueCat reconciliation with a test account, then release the native clients.

Do not release the clients before step 1. Keep JWT verification disabled only for `revenuecat-webhook` because RevenueCat authenticates with the configured authorization header.

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
