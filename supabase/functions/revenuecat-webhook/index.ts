import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.2";
import {
  lifetimeGrantUpdate,
  planAction,
  revokeUpdate,
  subscriptionGrantUpdate,
} from "../_shared/revenuecat-plan.ts";

// RevenueCat webhook: keeps profiles.subscription_status in step with in-app purchases
// (Google Play, App Store). The apps identify to RevenueCat with the profile's user_id,
// so event.app_user_id is the profile to update.
//
// Configure in RevenueCat > Integrations > Webhooks with this function's URL and an
// Authorization header value equal to the REVENUECAT_WEBHOOK_AUTH secret.

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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

    const action = planAction(event, Date.now());
    switch (action) {
      case "grant_lifetime":
      case "grant_subscription":
        for (const userId of userIds) await grant(supabaseClient, userId, event, action === "grant_lifetime");
        break;
      case "transfer":
        // A transfer names no product, so the receiving account gets Pro with no end
        // date recorded; a later renewal or expiration event carries the product.
        for (const userId of userIds) await grant(supabaseClient, userId, event, false);
        for (const userId of lostIds) await revoke(supabaseClient, userId, true);
        break;
      case "revoke_subscription":
      case "revoke_lifetime":
        for (const userId of userIds) await revoke(supabaseClient, userId, action === "revoke_lifetime");
        break;
      default:
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
async function readProfile(client: any, userId: string) {
  const { data: profile, error } = await client
    .from("profiles")
    .select("subscription_status, stripe_subscription_id, revenuecat_product_id")
    .eq("user_id", userId)
    .maybeSingle();
  if (error) throw new Error(error.message);
  return profile;
}

// deno-lint-ignore no-explicit-any
async function grant(client: any, userId: string, event: Record<string, unknown>, lifetime: boolean) {
  const profile = await readProfile(client, userId);
  if (!profile) {
    logStep("No profile for user, ignoring", { userId });
    return;
  }

  const update = lifetime ? lifetimeGrantUpdate(profile, event) : subscriptionGrantUpdate(profile, event);
  if (!update) {
    logStep("Plan already covers the purchase", { userId, type: event.type });
    return;
  }

  const { error } = await client.from("profiles").update(update).eq("user_id", userId);
  if (error) throw new Error(error.message);
  logStep(lifetime ? "Lifetime granted" : "Pro granted", { userId, type: event.type });
}

// deno-lint-ignore no-explicit-any
async function revoke(client: any, userId: string, lifetimeToo: boolean) {
  const profile = await readProfile(client, userId);
  if (!profile) return;

  const update = revokeUpdate(profile, lifetimeToo);
  if (!update) {
    logStep("Lifetime plan kept", { userId });
    return;
  }

  const { error } = await client.from("profiles").update(update).eq("user_id", userId);
  if (error) throw new Error(error.message);
  logStep("Store entitlement ended", { userId, plan: update.subscription_status ?? "unchanged" });
}
