import { writeFile } from "node:fs/promises";
import { chromium } from "playwright";

const email = process.env.AIDICTATION_RELEASE_TEST_EMAIL?.trim();
const password = process.env.AIDICTATION_RELEASE_TEST_PASSWORD?.trim();
const outputPath = process.env.AIDICTATION_RELEASE_AUTH_CALLBACK_PATH?.trim();

if (!email || !password || !outputPath) {
  throw new Error(
    "AIDICTATION_RELEASE_TEST_EMAIL, AIDICTATION_RELEASE_TEST_PASSWORD, and " +
      "AIDICTATION_RELEASE_AUTH_CALLBACK_PATH are required",
  );
}

const callbackScheme = "aidictation://auth-callback";
const authURL = new URL("https://aidictation.com/auth");
authURL.searchParams.set("redirect_to", callbackScheme);
authURL.searchParams.set("as_web_authentication_session", "1");

const browser = await chromium.launch({ headless: true });
const context = await browser.newContext();
const page = await context.newPage();

let resolveCallback;
let rejectCallback;
const callbackPromise = new Promise((resolve, reject) => {
  resolveCallback = resolve;
  rejectCallback = reject;
});

const timeout = setTimeout(() => {
  rejectCallback(new Error("Live browser sign-in did not produce an app callback"));
}, 45_000);

const captureCallback = (candidate) => {
  if (!candidate.startsWith(callbackScheme)) return;
  resolveCallback(candidate);
};

page.on("request", (request) => captureCallback(request.url()));
page.on("framenavigated", (frame) => captureCallback(frame.url()));
await page.route("aidictation://**", async (route) => {
  captureCallback(route.request().url());
  await route.abort();
});

try {
  await page.goto(authURL.toString(), { waitUntil: "domcontentloaded" });
  await page.locator("#email").fill(email);
  await page.locator("#password").fill(password);
  await page
    .getByRole("button", { name: "Sign In", exact: true })
    .click({ noWaitAfter: true });

  const callbackURL = await callbackPromise;
  const parsed = new URL(callbackURL);
  const callbackParams = new URLSearchParams(parsed.hash.replace(/^#/, ""));
  if (!callbackParams.get("access_token") || !callbackParams.get("refresh_token")) {
    throw new Error("Live browser callback did not contain a complete auth session");
  }

  await writeFile(outputPath, callbackURL, { encoding: "utf8", mode: 0o600 });
  console.log("Live browser sign-in produced an AIDictation app callback.");
} finally {
  clearTimeout(timeout);
  await browser.close();
}
