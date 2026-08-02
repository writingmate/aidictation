import { writeFile } from "node:fs/promises";
import { chromium } from "playwright";

const email = process.env.AIDICTATION_RELEASE_TEST_EMAIL?.trim();
const password = process.env.AIDICTATION_RELEASE_TEST_PASSWORD?.trim();
const outputPath = process.env.AIDICTATION_RELEASE_AUTH_CALLBACK_PATH?.trim();
const browserExecutable = process.env.AIDICTATION_RELEASE_AUTH_BROWSER_EXECUTABLE?.trim();
const isSelfTest = process.argv.includes("--self-test");

if (!isSelfTest && (!email || !password || !outputPath)) {
  throw new Error(
    "AIDICTATION_RELEASE_TEST_EMAIL, AIDICTATION_RELEASE_TEST_PASSWORD, and " +
      "AIDICTATION_RELEASE_AUTH_CALLBACK_PATH are required",
  );
}

const callbackScheme = "aidictation://auth-callback";
const authURL = new URL("https://aidictation.com/auth");
authURL.searchParams.set("redirect_to", callbackScheme);
authURL.searchParams.set("as_web_authentication_session", "1");

const browser = await chromium.launch({
  headless: true,
  ...(browserExecutable ? { executablePath: browserExecutable } : {}),
});
const context = await browser.newContext();
const page = await context.newPage();
const cdpSession = await context.newCDPSession(page);
await cdpSession.send("Page.enable");

let resolveCallback;
let rejectCallback;
let capturedCallback = null;
const callbackPromise = new Promise((resolve, reject) => {
  resolveCallback = resolve;
  rejectCallback = reject;
});

const timeout = setTimeout(
  () => {
    rejectCallback(new Error("Live browser sign-in did not produce a complete app callback"));
  },
  isSelfTest ? 10_000 : 45_000,
);

const exactCallbackURL = (candidate) => {
  let parsed;
  try {
    parsed = new URL(candidate);
  } catch {
    return null;
  }
  if (
    parsed.protocol !== "aidictation:" ||
    parsed.hostname !== "auth-callback" ||
    parsed.username ||
    parsed.password ||
    parsed.port ||
    (parsed.pathname && parsed.pathname !== "/")
  ) {
    return null;
  }
  return parsed;
};

const callbackParams = (parsed) => {
  const params = new URLSearchParams(parsed.search);
  const hashParams = new URLSearchParams(parsed.hash.replace(/^#/, ""));
  hashParams.forEach((value, key) => params.set(key, value));
  return params;
};

const captureCallback = (candidate) => {
  const parsed = exactCallbackURL(candidate);
  if (!parsed) return;
  const params = callbackParams(parsed);
  if (!params.get("access_token") || !params.get("refresh_token")) return;
  capturedCallback = candidate;
  resolveCallback(candidate);
};

// Network request URLs omit fragments. Capture the browser's requested navigation
// before the custom-protocol request loses the auth session fragment.
cdpSession.on("Page.frameScheduledNavigation", ({ url }) => captureCallback(url));
cdpSession.on("Page.frameRequestedNavigation", ({ url }) => captureCallback(url));
page.on("request", (request) => captureCallback(request.url()));
page.on("framenavigated", (frame) => captureCallback(frame.url()));
await page.route("aidictation://**", async (route) => {
  captureCallback(route.request().url());
  await route.abort();
});

try {
  if (isSelfTest) {
    await page.goto("about:blank");
    captureCallback(
      "aidictation://auth-callback[#access_token=synthetic-access&refresh_token=synthetic-refresh",
    );
    if (capturedCallback) {
      throw new Error("Custom-protocol callback capture accepted a malformed callback");
    }
    const navigate = async (url) => {
      await page
        .evaluate((target) => {
          setTimeout(() => {
            window.location.href = target;
          }, 0);
        }, url)
        .catch(() => {});
      await page.waitForTimeout(100);
    };
    const rejectedCallbacks = [
      `${callbackScheme}#access_token=synthetic-access`,
      "aidictation://auth-callback.evil#access_token=synthetic-access&refresh_token=synthetic-refresh",
      "aidictation://user@auth-callback#access_token=synthetic-access&refresh_token=synthetic-refresh",
      "aidictation://auth-callback:123#access_token=synthetic-access&refresh_token=synthetic-refresh",
      "aidictation://auth-callback/unexpected#access_token=synthetic-access&refresh_token=synthetic-refresh",
    ];
    for (const rejectedCallback of rejectedCallbacks) {
      await navigate(rejectedCallback);
      if (capturedCallback) {
        throw new Error("Custom-protocol callback capture accepted a mismatched callback");
      }
    }
    await navigate(
      `${callbackScheme}#access_token=synthetic-access&refresh_token=synthetic-refresh`,
    );
  } else {
    await page.goto(authURL.toString(), { waitUntil: "domcontentloaded" });
    await page.locator("#email").fill(email);
    await page.locator("#password").fill(password);
    await page
      .getByRole("button", { name: "Sign In", exact: true })
      .click({ noWaitAfter: true });
  }

  const callbackURL = await callbackPromise;
  const parsed = exactCallbackURL(callbackURL);
  const params = parsed ? callbackParams(parsed) : new URLSearchParams();
  if (!params.get("access_token") || !params.get("refresh_token")) {
    throw new Error("Live browser callback did not contain a complete auth session");
  }

  if (isSelfTest) {
    console.log("Verified complete custom-protocol callback capture.");
  } else {
    await writeFile(outputPath, callbackURL, { encoding: "utf8", mode: 0o600 });
    console.log("Live browser sign-in produced an AIDictation app callback.");
  }
} finally {
  clearTimeout(timeout);
  await browser.close();
}
