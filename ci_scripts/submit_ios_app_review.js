#!/usr/bin/env node

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const appBundleId = "com.whispermate.ios";
const platform = "IOS";
const locale = "en-US";
const repoRoot = path.resolve(__dirname, "..");
const metadataRoot = path.join(repoRoot, "Whishpermate", "fastlane", "metadata");

function requiredEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function readText(file) {
  return fs.readFileSync(file, "utf8").trim();
}

function metadataFile(...parts) {
  return readText(path.join(metadataRoot, ...parts));
}

function base64url(input) {
  return Buffer.from(input)
    .toString("base64")
    .replace(/=/g, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");
}

function token() {
  const keyId = requiredEnv("APP_STORE_CONNECT_API_KEY_KEY_ID");
  const issuerId = requiredEnv("APP_STORE_CONNECT_API_KEY_ISSUER_ID");
  const keyPath = requiredEnv("APP_STORE_CONNECT_API_KEY_KEY");
  const key = fs.readFileSync(keyPath, "utf8");
  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "ES256", kid: keyId, typ: "JWT" };
  const payload = {
    iss: issuerId,
    iat: now,
    exp: now + 20 * 60,
    aud: "appstoreconnect-v1"
  };
  const signingInput = `${base64url(JSON.stringify(header))}.${base64url(JSON.stringify(payload))}`;
  const signature = crypto.sign("sha256", Buffer.from(signingInput), {
    key,
    dsaEncoding: "ieee-p1363"
  });
  return `${signingInput}.${base64url(signature)}`;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function submissionTimeoutMs() {
  const configured = Number.parseInt(process.env.APP_REVIEW_SUBMISSION_TIMEOUT_MS || "", 10);
  return Number.isFinite(configured) && configured > 0 ? configured : 10 * 60 * 1000;
}

async function request(method, route, body, options = {}) {
  const attempts = options.attempts || 1;
  let lastError;

  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    const response = await fetch(`https://api.appstoreconnect.apple.com${route}`, {
      method,
      headers: {
        Authorization: `Bearer ${token()}`,
        "Content-Type": "application/json"
      },
      body: body ? JSON.stringify(body) : undefined
    });

    const text = await response.text();
    const json = text ? JSON.parse(text) : {};
    if (!response.ok) {
      const message = `App Store Connect API ${method} ${route} failed (${response.status}): ${text}`;
      lastError = new Error(message);
      if ((response.status >= 500 || response.status === 409) && attempt < attempts) {
        const delayMs = Math.min(60000, attempt * 15000);
        console.warn(`${message}\nRetrying in ${delayMs / 1000}s (${attempt + 1}/${attempts})...`);
        await sleep(delayMs);
        continue;
      }
      throw lastError;
    }

    return json;
  }

  throw lastError;
}

async function findApp() {
  const response = await request("GET", `/v1/apps?filter[bundleId]=${encodeURIComponent(appBundleId)}&limit=1`);
  const app = response.data && response.data[0];
  if (!app) {
    throw new Error(`No App Store Connect app found for ${appBundleId}`);
  }
  return app;
}

async function findAppStoreVersion(appId, marketingVersion) {
  const response = await request(
    "GET",
    `/v1/apps/${appId}/appStoreVersions?filter[platform]=${platform}&filter[versionString]=${encodeURIComponent(marketingVersion)}&limit=10`
  );
  const appStoreVersion = response.data && response.data[0];
  if (!appStoreVersion) {
    throw new Error(`No App Store version ${marketingVersion} found for ${appBundleId}`);
  }
  return appStoreVersion;
}

async function updateVersionMetadata(appStoreVersionId) {
  const copyright = metadataFile("copyright.txt");
  await request("PATCH", `/v1/appStoreVersions/${appStoreVersionId}`, {
    data: {
      type: "appStoreVersions",
      id: appStoreVersionId,
      attributes: {
        copyright,
        releaseType: "MANUAL"
      }
    }
  });

  const versionMetadata = {
    description: metadataFile(locale, "description.txt"),
    keywords: metadataFile(locale, "keywords.txt"),
    marketingUrl: metadataFile(locale, "marketing_url.txt"),
    promotionalText: metadataFile(locale, "promotional_text.txt"),
    supportUrl: metadataFile(locale, "support_url.txt")
  };

  const localizations = await request(
    "GET",
    `/v1/appStoreVersions/${appStoreVersionId}/appStoreVersionLocalizations?limit=200`
  );
  const localization = (localizations.data || []).find((item) => item.attributes && item.attributes.locale === locale);
  if (localization) {
    await request("PATCH", `/v1/appStoreVersionLocalizations/${localization.id}`, {
      data: {
        type: "appStoreVersionLocalizations",
        id: localization.id,
        attributes: versionMetadata
      }
    });
  } else {
    await request("POST", "/v1/appStoreVersionLocalizations", {
      data: {
        type: "appStoreVersionLocalizations",
        attributes: {
          locale,
          ...versionMetadata
        },
        relationships: {
          appStoreVersion: {
            data: {
              type: "appStoreVersions",
              id: appStoreVersionId
            }
          }
        }
      }
    });
  }

  console.log(`Updated ${locale} App Store version metadata`);
}

async function updateAppInfoMetadata(appId) {
  const appInfos = await request("GET", `/v1/apps/${appId}/appInfos?limit=20`);
  const appInfo = appInfos.data && appInfos.data[0];
  if (!appInfo) {
    console.warn("No appInfo resource found; skipping app-level localization metadata");
    return;
  }

  const appInfoMetadata = {
    privacyPolicyUrl: metadataFile(locale, "privacy_url.txt")
  };

  const localizations = await request("GET", `/v1/appInfos/${appInfo.id}/appInfoLocalizations?limit=200`);
  const localization = (localizations.data || []).find((item) => item.attributes && item.attributes.locale === locale);
  if (localization) {
    await request("PATCH", `/v1/appInfoLocalizations/${localization.id}`, {
      data: {
        type: "appInfoLocalizations",
        id: localization.id,
        attributes: appInfoMetadata
      }
    });
  } else {
    console.warn(`No ${locale} appInfo localization found; skipping app-level privacy URL update`);
    return;
  }

  console.log(`Updated ${locale} app info metadata`);
}

async function waitForBuild(appId, marketingVersion, buildNumber) {
  const query = [
    `filter[app]=${encodeURIComponent(appId)}`,
    `filter[preReleaseVersion.version]=${encodeURIComponent(marketingVersion)}`,
    `filter[version]=${encodeURIComponent(buildNumber)}`,
    "fields[builds]=version,uploadedDate,expired,processingState,usesNonExemptEncryption",
    "limit=200"
  ].join("&");

  const started = Date.now();
  const timeoutMs = 60 * 60 * 1000;
  while (Date.now() - started < timeoutMs) {
    const response = await request("GET", `/v1/builds?${query}`, undefined, { attempts: 3 });
    const build = (response.data || []).find((item) => item.attributes && item.attributes.version === buildNumber);
    if (!build) {
      console.log(`Build ${marketingVersion} (${buildNumber}) not visible in App Store Connect yet; waiting...`);
      await sleep(60000);
      continue;
    }

    const state = build.attributes.processingState;
    console.log(`Build ${marketingVersion} (${buildNumber}) processing state: ${state}`);
    if (state === "VALID") {
      return build;
    }
    if (state === "FAILED" || state === "INVALID") {
      throw new Error(`Build ${marketingVersion} (${buildNumber}) processing failed with state ${state}`);
    }

    await sleep(60000);
  }

  throw new Error(`Timed out waiting for build ${marketingVersion} (${buildNumber}) to finish processing`);
}

async function attachBuild(appStoreVersionId, build) {
  const buildId = build.id;
  const encryptionValue = build.attributes && build.attributes.usesNonExemptEncryption;

  if (encryptionValue === null || encryptionValue === undefined) {
    try {
      await request("PATCH", `/v1/builds/${buildId}`, {
        data: {
          type: "builds",
          id: buildId,
          attributes: {
            usesNonExemptEncryption: false
          }
        }
      }, { attempts: 4 });
    } catch (error) {
      if (!error.message.includes("/data/attributes/usesNonExemptEncryption") ||
          !error.message.includes("You cannot update when the value is already set")) {
        throw error;
      }
      console.log(`Build ${buildId} already has encryption metadata set`);
    }
  } else {
    console.log(`Build ${buildId} already has encryption metadata set`);
  }

  await request("PATCH", `/v1/appStoreVersions/${appStoreVersionId}/relationships/build`, {
    data: {
      type: "builds",
      id: buildId
    }
  }, { attempts: 6 });

  console.log(`Attached build ${buildId} to App Store version ${appStoreVersionId}`);
}

async function submitReviewSubmission(submissionId) {
  const started = Date.now();
  const timeoutMs = submissionTimeoutMs();
  let attempt = 1;

  while (Date.now() - started < timeoutMs) {
    try {
      const submittedResponse = await request("PATCH", `/v1/reviewSubmissions/${submissionId}`, {
        data: {
          type: "reviewSubmissions",
          id: submissionId,
          attributes: {
            submitted: true
          }
        }
      });

      console.log(`Submitted review submission ${submissionId}; state is ${submittedResponse.data.attributes.state}`);
      return submittedResponse.data;
    } catch (error) {
      const versionNotReady =
        error.message.includes("Version is not ready to be submitted yet") ||
        error.message.includes("is not in valid state");
      if (!versionNotReady) {
        throw error;
      }

      console.log(`Review submission ${submissionId} is not ready yet; waiting before retry ${attempt}`);
      attempt += 1;
      await sleep(60000);
    }
  }

  throw new Error(`Timed out waiting for review submission ${submissionId} to become submittable`);
}

async function submitForReview(appId, appStoreVersionId) {
  const active = await request(
    "GET",
    `/v1/reviewSubmissions?filter[app]=${appId}&filter[platform]=${platform}&filter[state]=READY_FOR_REVIEW,UNRESOLVED_ISSUES,WAITING_FOR_REVIEW,IN_REVIEW&include=items,appStoreVersionForReview&limit=50`
  );

  const submitted = (active.data || []).find((item) => {
    const state = item.attributes && item.attributes.state;
    return state === "WAITING_FOR_REVIEW" || state === "IN_REVIEW";
  });
  if (submitted) {
    console.log(`App is already submitted for review; submission ${submitted.id} is ${submitted.attributes.state}`);
    return submitted;
  }

  let submission = (active.data || []).find((item) => {
    const state = item.attributes && item.attributes.state;
    return state === "READY_FOR_REVIEW" || state === "UNRESOLVED_ISSUES";
  });
  if (!submission) {
    const created = await request("POST", "/v1/reviewSubmissions", {
      data: {
        type: "reviewSubmissions",
        attributes: {
          platform
        },
        relationships: {
          app: {
            data: {
              type: "apps",
              id: appId
            }
          }
        }
      }
    });
    submission = created.data;
    console.log(`Created review submission ${submission.id}`);
  } else {
    console.log(`Using existing review submission ${submission.id} in state ${submission.attributes.state}`);
  }

  const items = await request("GET", `/v1/reviewSubmissions/${submission.id}/items?include=appStoreVersion&limit=50`);
  const includedVersions = new Set((items.included || [])
    .filter((item) => item.type === "appStoreVersions")
    .map((item) => item.id));
  if (includedVersions.has(appStoreVersionId)) {
    console.log(`Review submission ${submission.id} already contains App Store version ${appStoreVersionId}`);
  } else {
    await request("POST", "/v1/reviewSubmissionItems", {
      data: {
        type: "reviewSubmissionItems",
        relationships: {
          reviewSubmission: {
            data: {
              type: "reviewSubmissions",
              id: submission.id
            }
          },
          appStoreVersion: {
            data: {
              type: "appStoreVersions",
              id: appStoreVersionId
            }
          }
        }
      }
    }, { attempts: 4 });
    console.log(`Added App Store version ${appStoreVersionId} to review submission ${submission.id}`);
  }

  return await submitReviewSubmission(submission.id);
}

async function main() {
  const marketingVersion = requiredEnv("IOS_MARKETING_VERSION");
  const buildNumber = requiredEnv("IOS_BUILD_NUMBER");
  const app = await findApp();
  const appStoreVersion = await findAppStoreVersion(app.id, marketingVersion);

  console.log(`Preparing App Store submission for ${appBundleId} ${marketingVersion} (${buildNumber})`);
  await updateVersionMetadata(appStoreVersion.id);
  await updateAppInfoMetadata(app.id);

  const build = await waitForBuild(app.id, marketingVersion, buildNumber);
  await attachBuild(appStoreVersion.id, build);
  await submitForReview(app.id, appStoreVersion.id);
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
