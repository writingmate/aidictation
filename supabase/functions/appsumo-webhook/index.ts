import { serve } from "https://deno.land/std@0.190.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.2";
import { tierToSeats } from "../_shared/appsumo-tiers.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-appsumo-signature, x-appsumo-timestamp",
};

const logStep = (step: string, details?: unknown) => {
  const detailsStr = details ? ` - ${JSON.stringify(details)}` : "";
  console.log(`[APPSUMO-WEBHOOK] ${step}${detailsStr}`);
};

const jsonResponse = (body: unknown, status: number) =>
  new Response(JSON.stringify(body), {
    headers: { ...corsHeaders, "Content-Type": "application/json" },
    status,
  });

// AppSumo signs each webhook with HMAC-SHA256 over `${timestamp}${rawBody}`
// using the partner API key, sent as X-Appsumo-Signature (hex) with
// X-Appsumo-Timestamp. See https://docs.licensing.appsumo.com/webhook/webhook__security.html
const hmacSha256Hex = async (key: string, message: string): Promise<string> => {
  const encoder = new TextEncoder();
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    encoder.encode(key),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", cryptoKey, encoder.encode(message));
  return Array.from(new Uint8Array(signature))
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
};

const timingSafeEqual = (a: string, b: string): boolean => {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) {
    diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  }
  return diff === 0;
};

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const supabaseClient = createClient(
    Deno.env.get("SUPABASE_URL") ?? "",
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
    { auth: { persistSession: false } },
  );

  try {
    logStep("Webhook received");

    const rawBody = await req.text();

    const apiKey = Deno.env.get("APPSUMO_API_KEY");
    if (apiKey) {
      const signature = req.headers.get("x-appsumo-signature") ?? "";
      const timestamp = req.headers.get("x-appsumo-timestamp") ?? "";
      const expected = await hmacSha256Hex(apiKey, `${timestamp}${rawBody}`);
      if (!timingSafeEqual(expected, signature.toLowerCase())) {
        logStep("Invalid webhook signature", { hasSignature: !!signature, hasTimestamp: !!timestamp });
        return jsonResponse({ error: "Invalid signature" }, 401);
      }
      logStep("Signature verified");
    } else {
      logStep("APPSUMO_API_KEY not set, skipping signature verification");
    }

    let body: Record<string, unknown>;
    try {
      body = JSON.parse(rawBody);
    } catch {
      logStep("Invalid JSON body");
      return jsonResponse({ error: "Invalid JSON" }, 400);
    }

    const event = body.event as string | undefined;
    const license_key = body.license_key as string | undefined;
    const prev_license_key = body.prev_license_key as string | undefined;
    const tier = body.tier;
    const activation_email = body.activation_email as string | undefined;
    const invoice_item_uuid = body.invoice_item_uuid as string | undefined;

    // AppSumo sends test requests (with fake data) to verify the webhook URL.
    if (body.test === true) {
      logStep("Test webhook, acknowledging without processing", { event });
      return jsonResponse({ success: true, event }, 200);
    }

    if (!event || !license_key) {
      logStep("Missing required fields", { event, license_key });
      return jsonResponse({ error: "Missing event or license_key" }, 400);
    }

    const licenseUuid = license_key;
    const tierNum = typeof tier === "number" ? tier : 1;
    const seats = tierToSeats(tierNum);

    logStep("Processing event", { event, licenseUuid, tier: tierNum, seats, activation_email });

    switch (event) {
      case "purchase": {
        const { error } = await supabaseClient
          .from("appsumo_licenses")
          .upsert({
            license_uuid: licenseUuid,
            tier: tierNum,
            seats,
            status: "active",
            invoice_item_uuid: invoice_item_uuid ?? null,
            appsumo_event: event,
            updated_at: new Date().toISOString(),
          }, { onConflict: "license_uuid" });

        if (error) {
          logStep("Failed to upsert license on purchase", { error: error.message });
          return jsonResponse({ error: "Database error" }, 500);
        }

        logStep("License created/updated on purchase", { licenseUuid, tier: tierNum, seats });
        break;
      }

      case "activate": {
        const updatePayload: Record<string, unknown> = {
          status: "active",
          tier: tierNum,
          seats,
          appsumo_event: event,
          updated_at: new Date().toISOString(),
        };

        if (activation_email) {
          updatePayload.activation_email = activation_email;

          // Try to link to an existing user by email
          const { data: userData } = await supabaseClient
            .from("profiles")
            .select("user_id")
            .eq("email", activation_email)
            .single();

          if (userData?.user_id) {
            updatePayload.user_id = userData.user_id;

            // Upgrade user to lifetime
            await supabaseClient
              .from("profiles")
              .update({ subscription_status: "lifetime" })
              .eq("user_id", userData.user_id);

            logStep("Linked license to existing user", { userId: userData.user_id, email: activation_email });
          } else {
            logStep("No user found for activation email, will link on login", { email: activation_email });
          }
        }

        const { error } = await supabaseClient
          .from("appsumo_licenses")
          .upsert({
            license_uuid: licenseUuid,
            ...updatePayload,
          }, { onConflict: "license_uuid" });

        if (error) {
          logStep("Failed to upsert license on activate", { error: error.message });
          return jsonResponse({ error: "Database error" }, 500);
        }

        logStep("License activated", { licenseUuid, tier: tierNum, activation_email });
        break;
      }

      case "upgrade":
      case "downgrade":
      case "migrate": {
        // AppSumo issues a NEW license_key for these events; prev_license_key
        // points at the license being replaced. Carry the old row forward.
        if (prev_license_key && prev_license_key !== licenseUuid) {
          const { data: migrated, error: migrateError } = await supabaseClient
            .from("appsumo_licenses")
            .update({
              license_uuid: licenseUuid,
              tier: tierNum,
              seats,
              status: "active",
              appsumo_event: event,
              updated_at: new Date().toISOString(),
            })
            .eq("license_uuid", prev_license_key)
            .select("id");

          if (migrateError) {
            logStep(`Failed to migrate license on ${event}`, { error: migrateError.message });
            return jsonResponse({ error: "Database error" }, 500);
          }

          if (migrated && migrated.length > 0) {
            logStep(`License ${event}d from previous key`, {
              licenseUuid,
              prevLicenseUuid: prev_license_key,
              tier: tierNum,
              seats,
            });
            break;
          }
          logStep("No row found for prev_license_key, upserting new license", { prev_license_key });
        }

        const { error } = await supabaseClient
          .from("appsumo_licenses")
          .upsert({
            license_uuid: licenseUuid,
            tier: tierNum,
            seats,
            status: "active",
            appsumo_event: event,
            updated_at: new Date().toISOString(),
          }, { onConflict: "license_uuid" });

        if (error) {
          logStep(`Failed to update license on ${event}`, { error: error.message });
          return jsonResponse({ error: "Database error" }, 500);
        }

        logStep(`License ${event}d`, { licenseUuid, tier: tierNum, seats });
        break;
      }

      case "deactivate": {
        // Get the license to find linked user
        const { data: licenseData } = await supabaseClient
          .from("appsumo_licenses")
          .select("user_id")
          .eq("license_uuid", licenseUuid)
          .single();

        const { error } = await supabaseClient
          .from("appsumo_licenses")
          .update({
            status: "deactivated",
            appsumo_event: event,
            updated_at: new Date().toISOString(),
          })
          .eq("license_uuid", licenseUuid);

        if (error) {
          logStep("Failed to deactivate license", { error: error.message });
          return jsonResponse({ error: "Database error" }, 500);
        }

        // Check if user has any other active entitlements
        if (licenseData?.user_id) {
          const userId = licenseData.user_id;

          const { count: otherLicenses } = await supabaseClient
            .from("appsumo_licenses")
            .select("id", { count: "exact", head: true })
            .eq("user_id", userId)
            .eq("status", "active");

          const { count: promoCodes } = await supabaseClient
            .from("promo_codes")
            .select("id", { count: "exact", head: true })
            .eq("redeemed_by", userId);

          if ((otherLicenses ?? 0) === 0 && (promoCodes ?? 0) === 0) {
            await supabaseClient
              .from("profiles")
              .update({ subscription_status: "free" })
              .eq("user_id", userId);

            logStep("User downgraded to free (no remaining entitlements)", { userId });
          }
        }

        logStep("License deactivated", { licenseUuid });
        break;
      }

      default:
        logStep("Unknown event type, ignoring", { event });
    }

    // AppSumo requires the event echoed back alongside success=true.
    return jsonResponse({ success: true, event }, 200);
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    logStep("ERROR", { message: errorMessage });
    return jsonResponse({ error: errorMessage }, 500);
  }
});
