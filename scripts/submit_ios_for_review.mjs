#!/usr/bin/env node
// Promotes the build an ios-v tag just uploaded to an App Store submission:
// waits for Apple to finish processing it, creates (or reuses) the version record,
// writes the release notes, attaches the build, and submits for review.
//
// Idempotent — a re-run picks up whatever already exists rather than duplicating it.
//
// Required env:
//   APP_STORE_CONNECT_API_KEY_KEY_ID
//   APP_STORE_CONNECT_API_KEY_ISSUER_ID
//   APP_STORE_CONNECT_API_KEY_KEY      path to the .p8
//   IOS_MARKETING_VERSION              version string to submit, e.g. 0.0.98
// Optional env:
//   IOS_BUNDLE_ID                      default com.whispermate.ios
//   IOS_RELEASE_TYPE                   AFTER_APPROVAL (default) or MANUAL
//   IOS_RELEASE_NOTES_FILE             default Whishpermate/fastlane/metadata/en-US/release_notes.txt
//   IOS_BUILD_WAIT_MINUTES             default 45

import crypto from "crypto";
import fs from "fs";

const KEY_ID = required("APP_STORE_CONNECT_API_KEY_KEY_ID");
const ISSUER_ID = required("APP_STORE_CONNECT_API_KEY_ISSUER_ID");
const KEY_PATH = required("APP_STORE_CONNECT_API_KEY_KEY");
const VERSION = required("IOS_MARKETING_VERSION");
const BUNDLE_ID = process.env.IOS_BUNDLE_ID || "com.whispermate.ios";
const RELEASE_TYPE = process.env.IOS_RELEASE_TYPE || "AFTER_APPROVAL";
const NOTES_FILE = process.env.IOS_RELEASE_NOTES_FILE || "Whishpermate/fastlane/metadata/en-US/release_notes.txt";
const WAIT_MINUTES = Number(process.env.IOS_BUILD_WAIT_MINUTES || 45);

function required(name) {
  const value = process.env[name];
  if (!value) {
    console.error(`::error::Missing required env: ${name}`);
    process.exit(1);
  }
  return value;
}

const privateKey = fs.readFileSync(KEY_PATH, "utf8");

function token() {
  const b64 = (input) =>
    Buffer.from(input).toString("base64").replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_");
  const now = Math.floor(Date.now() / 1000);
  const signingInput = `${b64(JSON.stringify({ alg: "ES256", kid: KEY_ID, typ: "JWT" }))}.${b64(
    JSON.stringify({ iss: ISSUER_ID, iat: now, exp: now + 1200, aud: "appstoreconnect-v1" })
  )}`;
  const signature = crypto.sign("sha256", Buffer.from(signingInput), {
    key: privateKey,
    dsaEncoding: "ieee-p1363",
  });
  return `${signingInput}.${signature.toString("base64").replace(/=/g, "").replace(/\+/g, "-").replace(/\//g, "_")}`;
}

async function api(method, path, body) {
  const res = await fetch(`https://api.appstoreconnect.apple.com/v1/${path}`, {
    method,
    headers: { Authorization: `Bearer ${token()}`, "Content-Type": "application/json" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  const json = text ? JSON.parse(text) : {};
  if (!res.ok) {
    throw new Error(`${method} ${path} -> ${res.status}\n${JSON.stringify(json.errors ?? json, null, 2)}`);
  }
  return json;
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

const apps = await api("GET", `apps?filter[bundleId]=${BUNDLE_ID}`);
const app = apps.data?.[0];
if (!app) throw new Error(`No app found for bundle id ${BUNDLE_ID}`);
console.log(`app: ${app.attributes.name} (${app.id})`);

// The upload step finishes well before Apple finishes processing, so poll for a usable build.
async function processedBuild() {
  const builds = await api(
    "GET",
    `builds?filter[app]=${app.id}&limit=20&sort=-uploadedDate&include=preReleaseVersion`
  );
  const matching = (builds.data ?? []).filter((build) => {
    const pre = builds.included?.find((i) => i.id === build.relationships?.preReleaseVersion?.data?.id);
    return pre?.attributes?.version === VERSION;
  });
  return matching[0] ?? null;
}

let build = null;
const deadline = Date.now() + WAIT_MINUTES * 60 * 1000;
while (Date.now() < deadline) {
  const candidate = await processedBuild();
  if (!candidate) {
    console.log(`waiting for a build of ${VERSION} to appear...`);
  } else if (candidate.attributes.processingState === "VALID") {
    build = candidate;
    break;
  } else if (["INVALID", "FAILED"].includes(candidate.attributes.processingState)) {
    throw new Error(`Build ${candidate.attributes.version} is ${candidate.attributes.processingState}`);
  } else {
    console.log(`build ${candidate.attributes.version}: ${candidate.attributes.processingState}`);
  }
  await sleep(60_000);
}
if (!build) throw new Error(`No VALID build for ${VERSION} within ${WAIT_MINUTES} minutes`);
console.log(`build ${build.attributes.version} (${build.id}) is VALID`);

const versions = await api("GET", `apps/${app.id}/appStoreVersions?filter[versionString]=${VERSION}&limit=1`);
let version = versions.data?.[0];
if (version) {
  console.log(`version ${VERSION} exists (${version.id}) state=${version.attributes.appStoreState}`);
} else {
  version = (
    await api("POST", "appStoreVersions", {
      data: {
        type: "appStoreVersions",
        attributes: { platform: "IOS", versionString: VERSION, releaseType: RELEASE_TYPE },
        relationships: { app: { data: { type: "apps", id: app.id } } },
      },
    })
  ).data;
  console.log(`created version ${VERSION} (${version.id}) releaseType=${RELEASE_TYPE}`);
}

if (fs.existsSync(NOTES_FILE)) {
  const whatsNew = fs.readFileSync(NOTES_FILE, "utf8").trim();
  const locs = await api("GET", `appStoreVersions/${version.id}/appStoreVersionLocalizations?limit=50`);
  const enUS = locs.data?.find((l) => l.attributes.locale === "en-US");
  if (enUS) {
    await api("PATCH", `appStoreVersionLocalizations/${enUS.id}`, {
      data: { type: "appStoreVersionLocalizations", id: enUS.id, attributes: { whatsNew } },
    });
    console.log("updated en-US release notes");
  } else {
    await api("POST", "appStoreVersionLocalizations", {
      data: {
        type: "appStoreVersionLocalizations",
        attributes: { locale: "en-US", whatsNew },
        relationships: { appStoreVersion: { data: { type: "appStoreVersions", id: version.id } } },
      },
    });
    console.log("created en-US release notes");
  }
} else {
  console.log(`no release notes at ${NOTES_FILE}; leaving existing notes alone`);
}

await api("PATCH", `appStoreVersions/${version.id}/relationships/build`, {
  data: { type: "builds", id: build.id },
});
console.log("attached build to version");

const openStates = "READY_FOR_REVIEW,WAITING_FOR_REVIEW,IN_REVIEW,UNRESOLVED_ISSUES";
const existing = await api("GET", `reviewSubmissions?filter[app]=${app.id}&filter[state]=${openStates}&limit=10`);
let submission = existing.data?.[0];
if (submission) {
  console.log(`reusing review submission ${submission.id} (${submission.attributes.state})`);
} else {
  submission = (
    await api("POST", "reviewSubmissions", {
      data: {
        type: "reviewSubmissions",
        attributes: { platform: "IOS" },
        relationships: { app: { data: { type: "apps", id: app.id } } },
      },
    })
  ).data;
  console.log(`created review submission ${submission.id}`);
}

const items = await api("GET", `reviewSubmissions/${submission.id}/items?limit=50`);
if (!items.data?.some((i) => i.relationships?.appStoreVersion?.data?.id === version.id)) {
  await api("POST", "reviewSubmissionItems", {
    data: {
      type: "reviewSubmissionItems",
      relationships: {
        reviewSubmission: { data: { type: "reviewSubmissions", id: submission.id } },
        appStoreVersion: { data: { type: "appStoreVersions", id: version.id } },
      },
    },
  });
  console.log(`added ${VERSION} to the submission`);
}

if (submission.attributes.state === "READY_FOR_REVIEW") {
  await api("PATCH", `reviewSubmissions/${submission.id}`, {
    data: { type: "reviewSubmissions", id: submission.id, attributes: { submitted: true } },
  });
  console.log("submitted for review");
} else {
  console.log(`submission is ${submission.attributes.state}; nothing to submit`);
}

const final = await api("GET", `appStoreVersions/${version.id}`);
console.log(
  `final: ${VERSION} state=${final.data.attributes.appStoreState} releaseType=${final.data.attributes.releaseType}`
);
