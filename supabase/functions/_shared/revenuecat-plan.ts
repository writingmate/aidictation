// Plan rules for RevenueCat webhook events, kept free of I/O so they can be tested.
//
// profiles.subscription_status is "free", "pro" (a subscription) or "lifetime". The
// revenuecat_* columns record what the store purchase is, so a plan that came from the
// store can be told apart from one that came from Stripe, AppSumo or a promo code.

export const PRO_ENTITLEMENT = "pro";
export const LIFETIME_PRODUCT_ID = "lifetime";

// Events after which the entitlement is active until expiration_at_ms.
const GRANTING_EVENTS = new Set([
  "INITIAL_PURCHASE",
  "RENEWAL",
  "UNCANCELLATION",
  "NON_RENEWING_PURCHASE",
  "PRODUCT_CHANGE",
  "SUBSCRIPTION_EXTENDED",
  "TEMPORARY_ENTITLEMENT_GRANT",
]);

export type RevenueCatEvent = Record<string, unknown>;

export type StoreProfile = {
  subscription_status?: string | null;
  stripe_subscription_id?: string | null;
  revenuecat_product_id?: string | null;
};

export type PlanAction =
  | "grant_lifetime"
  | "grant_subscription"
  | "revoke_subscription"
  | "revoke_lifetime"
  | "transfer"
  | "none";

/** Google Play subscription ids arrive as `product:base-plan`; the product part decides. */
export const isLifetimeProduct = (productId: unknown): boolean =>
  typeof productId === "string" &&
  productId.split(":")[0].toLowerCase() === LIFETIME_PRODUCT_ID;

export const expirationMs = (event: RevenueCatEvent): number | null =>
  typeof event.expiration_at_ms === "number" ? event.expiration_at_ms : null;

/** The profile holds a Lifetime plan that was bought in the store. */
const hasStoreLifetime = (profile: StoreProfile): boolean =>
  profile.subscription_status === "lifetime" && isLifetimeProduct(profile.revenuecat_product_id);

/** What an event means for the plan of the profiles it concerns. */
export function planAction(event: RevenueCatEvent, nowMs: number): PlanAction {
  const type = typeof event.type === "string" ? event.type : "";
  if (type === "TRANSFER") return "transfer";

  const lifetime = isLifetimeProduct(event.product_id);
  const entitlementIds = Array.isArray(event.entitlement_ids) ? event.entitlement_ids : [];
  if (GRANTING_EVENTS.has(type) && entitlementIds.includes(PRO_ENTITLEMENT)) {
    const expiresAtMs = expirationMs(event);
    // A one-time purchase has no expiry: the Lifetime product, bought once.
    if (lifetime && expiresAtMs === null) return "grant_lifetime";
    if (expiresAtMs === null || expiresAtMs > nowMs) return "grant_subscription";
    return "none";
  }
  if (type === "EXPIRATION") return lifetime ? "revoke_lifetime" : "revoke_subscription";
  // A refund of a one-time purchase arrives as a cancellation; nothing expires later.
  if (type === "CANCELLATION" && lifetime && event.cancel_reason === "CUSTOMER_SUPPORT") {
    return "revoke_lifetime";
  }
  // Other cancellations and billing issues leave the entitlement active until EXPIRATION.
  return "none";
}

const storeFields = (event: RevenueCatEvent) => ({
  revenuecat_expires_at: expirationMs(event) === null
    ? null
    : new Date(expirationMs(event) as number).toISOString(),
  revenuecat_product_id: typeof event.product_id === "string" ? event.product_id : null,
  revenuecat_store: typeof event.store === "string" ? event.store : null,
});

/** The profile changes for a Lifetime purchase, or null when nothing changes. */
export function lifetimeGrantUpdate(
  profile: StoreProfile,
  event: RevenueCatEvent,
): Record<string, unknown> | null {
  // A Lifetime plan from another source (AppSumo, promo code) stays that source's: a
  // refund of this purchase must not take it away.
  if (profile.subscription_status === "lifetime" && !hasStoreLifetime(profile)) return null;
  return { ...storeFields(event), revenuecat_expires_at: null, subscription_status: "lifetime" };
}

/** The profile changes for an active subscription, or null when nothing changes. */
export function subscriptionGrantUpdate(
  profile: StoreProfile,
  event: RevenueCatEvent,
): Record<string, unknown> | null {
  // The Lifetime purchase stays on record: a subscription running beside it changes nothing.
  if (hasStoreLifetime(profile)) return null;
  const update: Record<string, unknown> = storeFields(event);
  // A lifetime plan outranks a subscription and is never overwritten by one.
  if (profile.subscription_status !== "lifetime") update.subscription_status = "pro";
  return update;
}

/**
 * The profile changes when a store purchase ends, or null when nothing changes.
 * `lifetimeToo` is set when the Lifetime purchase itself is refunded or moved to another
 * account; a subscription ending never touches a Lifetime plan.
 */
export function revokeUpdate(
  profile: StoreProfile,
  lifetimeToo: boolean,
): Record<string, unknown> | null {
  const storeLifetime = hasStoreLifetime(profile);
  if (storeLifetime && !lifetimeToo) return null;

  const update: Record<string, unknown> = {
    revenuecat_expires_at: null,
    revenuecat_product_id: null,
    revenuecat_store: null,
  };
  // Only a plan that came from the store ends here: a Stripe subscription on the same
  // account keeps it on Pro, and a Lifetime plan from another source is left alone.
  if (storeLifetime) {
    update.subscription_status = profile.stripe_subscription_id ? "pro" : "free";
  } else if (profile.subscription_status === "pro" && !profile.stripe_subscription_id) {
    update.subscription_status = "free";
  }
  return update;
}
