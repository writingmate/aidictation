-- In-app purchases through RevenueCat (Google Play, App Store).
-- The revenuecat-webhook function records the Pro entitlement here so that other
-- entitlement sources (Stripe, AppSumo, promo codes) can tell it apart from their own.
alter table public.profiles
  add column if not exists revenuecat_expires_at timestamptz,
  add column if not exists revenuecat_product_id text,
  add column if not exists revenuecat_store text;
