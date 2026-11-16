// Run with `node --test supabase/functions/_shared/revenuecat-plan.test.ts` (Node 24+)
// or `deno test`.
import assert from "node:assert/strict";
import { test } from "node:test";
import {
  isLifetimeProduct,
  lifetimeGrantUpdate,
  planAction,
  revokeUpdate,
  subscriptionGrantUpdate,
} from "./revenuecat-plan.ts";

const NOW = Date.UTC(2026, 10, 15);
const DAY = 24 * 60 * 60 * 1000;

const lifetimePurchase = {
  type: "NON_RENEWING_PURCHASE",
  product_id: "lifetime",
  entitlement_ids: ["pro"],
  expiration_at_ms: null,
  store: "PLAY_STORE",
};
const renewal = {
  type: "RENEWAL",
  product_id: "yearly:annual-base",
  entitlement_ids: ["pro"],
  expiration_at_ms: NOW + 365 * DAY,
  store: "PLAY_STORE",
};

test("lifetime product ids match with or without a base plan", () => {
  assert.equal(isLifetimeProduct("lifetime"), true);
  assert.equal(isLifetimeProduct("Lifetime:base"), true);
  assert.equal(isLifetimeProduct("yearly"), false);
  assert.equal(isLifetimeProduct(null), false);
});

test("a one-time purchase of the lifetime product grants lifetime", () => {
  assert.equal(planAction(lifetimePurchase, NOW), "grant_lifetime");
  assert.deepEqual(lifetimeGrantUpdate({ subscription_status: "free" }, lifetimePurchase), {
    revenuecat_expires_at: null,
    revenuecat_product_id: "lifetime",
    revenuecat_store: "PLAY_STORE",
    subscription_status: "lifetime",
  });
});

test("lifetime replaces a running store subscription", () => {
  const update = lifetimeGrantUpdate(
    { subscription_status: "pro", revenuecat_product_id: "monthly" },
    lifetimePurchase,
  );
  assert.equal(update?.subscription_status, "lifetime");
  assert.equal(update?.revenuecat_product_id, "lifetime");
});

test("a lifetime plan from another source is not claimed by the store purchase", () => {
  assert.equal(lifetimeGrantUpdate({ subscription_status: "lifetime" }, lifetimePurchase), null);
});

test("a subscription event grants pro until its expiry", () => {
  assert.equal(planAction(renewal, NOW), "grant_subscription");
  const update = subscriptionGrantUpdate({ subscription_status: "free" }, renewal);
  assert.equal(update?.subscription_status, "pro");
  assert.equal(update?.revenuecat_product_id, "yearly:annual-base");
  assert.equal(update?.revenuecat_expires_at, new Date(NOW + 365 * DAY).toISOString());
});

test("an already expired subscription event grants nothing", () => {
  assert.equal(planAction({ ...renewal, expiration_at_ms: NOW - DAY }, NOW), "none");
});

test("an event without the pro entitlement grants nothing", () => {
  assert.equal(planAction({ ...lifetimePurchase, entitlement_ids: [] }, NOW), "none");
});

test("a subscription beside a store lifetime leaves the profile alone", () => {
  const profile = { subscription_status: "lifetime", revenuecat_product_id: "lifetime" };
  assert.equal(subscriptionGrantUpdate(profile, renewal), null);
});

test("a subscription never overwrites a lifetime plan from another source", () => {
  const update = subscriptionGrantUpdate({ subscription_status: "lifetime" }, renewal);
  assert.equal(update?.subscription_status, undefined);
});

test("a subscription expiry does not downgrade a store lifetime", () => {
  const expiration = { type: "EXPIRATION", product_id: "monthly", entitlement_ids: ["pro"] };
  assert.equal(planAction(expiration, NOW), "revoke_subscription");
  const profile = { subscription_status: "lifetime", revenuecat_product_id: "lifetime" };
  assert.equal(revokeUpdate(profile, false), null);
});

test("a subscription expiry does not downgrade a lifetime plan from another source", () => {
  const update = revokeUpdate({ subscription_status: "lifetime", revenuecat_product_id: "monthly" }, false);
  assert.equal(update?.subscription_status, undefined);
  assert.equal(update?.revenuecat_product_id, null);
});

test("a subscription expiry downgrades a store subscriber", () => {
  const update = revokeUpdate({ subscription_status: "pro", revenuecat_product_id: "monthly" }, false);
  assert.equal(update?.subscription_status, "free");
});

test("a subscription expiry keeps an account that also pays through Stripe", () => {
  const update = revokeUpdate(
    { subscription_status: "pro", stripe_subscription_id: "sub_123", revenuecat_product_id: "monthly" },
    false,
  );
  assert.equal(update?.subscription_status, undefined);
});

test("a refunded lifetime purchase ends the store lifetime", () => {
  const refund = { type: "CANCELLATION", product_id: "lifetime", cancel_reason: "CUSTOMER_SUPPORT" };
  assert.equal(planAction(refund, NOW), "revoke_lifetime");
  const profile = { subscription_status: "lifetime", revenuecat_product_id: "lifetime" };
  assert.equal(revokeUpdate(profile, true)?.subscription_status, "free");
  assert.equal(revokeUpdate({ ...profile, stripe_subscription_id: "sub_123" }, true)?.subscription_status, "pro");
});

test("a subscription cancellation waits for the expiration event", () => {
  const cancellation = { type: "CANCELLATION", product_id: "monthly", cancel_reason: "UNSUBSCRIBE" };
  assert.equal(planAction(cancellation, NOW), "none");
  assert.equal(planAction({ ...cancellation, cancel_reason: "CUSTOMER_SUPPORT" }, NOW), "none");
});

test("a transfer is its own action", () => {
  assert.equal(planAction({ type: "TRANSFER" }, NOW), "transfer");
});
