import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.2";

// RevenueCat webhook: keeps profiles.subscription_status in step with in-app purchases
// (Google Play, App Store). The apps identify to RevenueCat with the profile's user_id,
// so event.app_user_id is the profile to update.
//
// Configure in RevenueCat > Integrations > Webhooks with this function's URL and an
// Authorization header value equal to the REVENUECAT_WEBHOOK_AUTH secret.

const PRO_ENTITLEMENT = "pro";
const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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

const logStep = (step: string, details?: unknown) => {
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : "";
  console.log(`[REVENUECAT-WEBHOOK] ${step}${detailsStr}`);
};

const jsonResponse = (body: unknown, status: number) =>
  new Response(JSON.stringify(body), {
    headers: { "Content-Type": "application/json" },
    status,
  });

const timingSafeEqual = (a: string, b: string): boolean => {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
};

/** The profile ids an event concerns: RevenueCat lists every id the customer has used. */
const profileIds = (event: Record<string, unknown>): string[] => {
  const candidates = [
    event.app_user_id,
    event.original_app_user_id,
    ...(Array.isArray(event.aliases) ? event.aliases : []),
  ];
  return [...new Set(candidates.filter((id): id is string => typeof id === "string" && UUID_PATTERN.test(id)))];
};

serve(async (req) => {
  if (req.method !== "POST") return jsonResponse({ error: "Method not allowed" }, 405);

  const expectedAuth = Deno.env.get("REVENUECAT_WEBHOOK_AUTH") ?? "";
  const providedAuth = req.headers.get("authorization") ?? "";
  if (!expectedAuth || !timingSafeEqual(providedAuth, expectedAuth)) {
    logStep("Rejected: bad authorization header");
    return jsonResponse({ error: "Unauthorized" }, 401);
  }

  const supabaseClient = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    { auth: { persistSession: false } },
  );

  try {
    const payload = await req.json();
    const event = payload?.event as Record<string, unknown> | undefined;
    const type = typeof event?.type === "string" ? event.type : "";
    if (!event || !type) return jsonResponse({ error: "Missing event" }, 400);

    // A purchase made before sign-in has only an anonymous RevenueCat id. It reaches a
    // profile when the app logs in and RevenueCat sends the transfer or next renewal.
    const userIds = type === "TRANSFER"
      ? (Array.isArray(event.transferred_to) ? event.transferred_to : [])
        .filter((id): id is string => typeof id === "string" && UUID_PATTERN.test(id))
      : profileIds(event);
    const lostIds = type === "TRANSFER"
      ? (Array.isArray(event.transferred_from) ? event.transferred_from : [])
        .filter((id): id is string => typeof id === "string" && UUID_PATTERN.test(id))
      : [];

    const entitlementIds = Array.isArray(event.entitlement_ids) ? event.entitlement_ids : [];
    const expiresAtMs = typeof event.expiration_at_ms === "number" ? event.expiration_at_ms : null;
    const grantsPro = (GRANTING_EVENTS.has(type) && entitlementIds.includes(PRO_ENTITLEMENT)) ||
      type === "TRANSFER";
    const active = grantsPro && (expiresAtMs === null || expiresAtMs > Date.now());

    if (active) {
      for (const userId of userIds) await grantPro(supabaseClient, userId, event, expiresAtMs);
      for (const userId of lostIds) await revokePro(supabaseClient, userId);
    } else if (type === "EXPIRATION") {
      for (const userId of userIds) await revokePro(supabaseClient, userId);
    } else {
      // CANCELLATION and BILLING_ISSUE leave the entitlement active until EXPIRATION.
      logStep("No plan change for event", { type });
    }

    return jsonResponse({ success: true }, 200);
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    logStep("ERROR", { message: errorMessage });
    // A non-2xx answer makes RevenueCat retry the event.
    return jsonResponse({ error: errorMessage }, 500);
  }
});

// deno-lint-ignore no-explicit-any
async function grantPro(client: any, userId: string, event: Record<string, unknown>, expiresAtMs: number | null) {
  const { data: profile, error: readError } = await client
    .from("profiles")
    .select("subscription_status")
    .eq("user_id", userId)
    .maybeSingle();
  if (readError) throw new Error(readError.message);
  if (!profile) {
    logStep("No profile for user, ignoring", { userId });
    return;
  }

  const update: Record<string, unknown> = {
    revenuecat_expires_at: expiresAtMs === null ? null : new Date(expiresAtMs).toISOString(),
    revenuecat_product_id: typeof event.product_id === "string" ? event.product_id : null,
    revenuecat_store: typeof event.store === "string" ? event.store : null,
  };
  // A lifetime plan outranks a subscription and is never overwritten by one.
  if (profile.subscription_status !== "lifetime") update.subscription_status = "pro";

  const { error } = await client.from("profiles").update(update).eq("user_id", userId);
  if (error) throw new Error(error.message);
  logStep("Pro granted", { userId, type: event.type });
}

// deno-lint-ignore no-explicit-any
async function revokePro(client: any, userId: string) {
  const { data: profile, error: readError } = await client
    .from("profiles")
    .select("subscription_status, stripe_subscription_id")
    .eq("user_id", userId)
    .maybeSingle();
  if (readError) throw new Error(readError.message);
  if (!profile) return;

  const update: Record<string, unknown> = {
    revenuecat_expires_at: null,
    revenuecat_product_id: null,
    revenuecat_store: null,
  };
  // Only a plan that came from the store purchase ends here: a lifetime plan or a
  // Stripe subscription on the same account keeps the account paid.
  if (profile.subscription_status === "pro" && !profile.stripe_subscription_id) {
    update.subscription_status = "free";
  }

  const { error } = await client.from("profiles").update(update).eq("user_id", userId);
  if (error) throw new Error(error.message);
  logStep("Store entitlement ended", { userId, downgraded: update.subscription_status === "free" });
}
