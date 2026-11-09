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

async function apiOptional(method, path) {
  try {
    return await api(method, path);
  } catch (error) {
    if (String(error.message).includes("-> 404")) return null;
    throw error;
  }
}

const EDITABLE_APP_INFO_STATES = new Set([
  "PREPARE_FOR_SUBMISSION",
  "READY_FOR_REVIEW",
  "WAITING_FOR_REVIEW",
  "IN_REVIEW",
  "UNRESOLVED_ISSUES",
  "REJECTED",
  "DEVELOPER_REJECTED",
  "METADATA_REJECTED",
  "INVALID_BINARY",
]);

async function patchAgeRating(id, attributes) {
  await api("PATCH", `ageRatingDeclarations/${id}`, {
    data: { type: "ageRatingDeclarations", id, attributes },
  });
}

async function declareNoSocialMedia(appId, versionId) {
  const declarations = new Map();
  const remember = (id, attributes = {}) => {
    if (!id || declarations.has(id)) return;
    declarations.set(id, attributes);
  };

  const fromVersion = await apiOptional("GET", `appStoreVersions/${versionId}/ageRatingDeclaration`);
  if (fromVersion?.data?.id) remember(fromVersion.data.id, fromVersion.data.attributes ?? {});

  // Apple allows UPDATE on this resource and rejects GET_INSTANCE, so use the
  // id from the app info relationship and do not read the declaration itself.
  const infos = await api("GET", `apps/${appId}/appInfos?include=ageRatingDeclaration&limit=20`);
  for (const info of infos.data ?? []) {
    const state = info.attributes?.state ?? "unknown";
    const declarationId = info.relationships?.ageRatingDeclaration?.data?.id;
    console.log(`app info ${info.id} state=${state} ageRating=${declarationId ?? "none"}`);
    if (!EDITABLE_APP_INFO_STATES.has(state)) continue;
    const included = (infos.included ?? []).find((item) => item.id === declarationId);
    remember(declarationId, included?.attributes ?? {});
  }
  remember(versionId, {});

  if (declarations.size === 0) throw new Error(`No age rating declaration for version ${versionId}`);

  const errors = [];
  let updated = false;
  for (const [id, attributes] of declarations) {
    const patch = {};
    if (attributes.socialMedia == null) patch.socialMedia = false;
    if (attributes.socialMediaAgeRestricted == null) patch.socialMediaAgeRestricted = false;
    if (Object.keys(patch).length === 0) {
      console.log(`age rating ${id} already answers social media`);
      updated = true;
      continue;
    }
    try {
      await patchAgeRating(id, patch);
      console.log(`age rating ${id} updated: ${JSON.stringify(patch)}`);
      updated = true;
    } catch (error) {
      if (!("socialMedia" in patch)) {
        errors.push(error);
        console.log(`age rating ${id} not updated: ${String(error.message).split("\n")[0]}`);
        continue;
      }
      try {
        await patchAgeRating(id, { socialMedia: false });
        console.log(`age rating ${id} updated: socialMedia=false`);
        updated = true;
      } catch (fallbackError) {
        errors.push(fallbackError);
        console.log(`age rating ${id} not updated: ${String(fallbackError.message).split("\n")[0]}`);
      }
    }
  }
  if (!updated) throw errors[0] ?? new Error(`No age rating declaration for version ${versionId}`);
}

const apps = await api("GET", `apps?filter[bundleId]=${BUNDLE_ID}`);
const app = apps.data?.[0];
if (!app) throw new Error(`No app found for bundle id ${BUNDLE_ID}`);
console.log(`app: ${app.attributes.name} (${app.id})`);

// The upload step finishes well before Apple finishes processing, so poll for a usable build.
function buildNumber(build) {
  const parsed = Number.parseInt(build?.attributes?.version, 10);
  return Number.isFinite(parsed) ? parsed : -1;
}

async function processedBuild() {
  const builds = await api(
    "GET",
    `builds?filter[app]=${app.id}&limit=200&sort=-uploadedDate&include=preReleaseVersion`
  );
  const matching = (builds.data ?? []).filter((build) => {
    const pre = builds.included?.find((i) => i.id === build.relationships?.preReleaseVersion?.data?.id);
    return pre?.attributes?.version === VERSION;
  });
  matching.sort((left, right) => buildNumber(right) - buildNumber(left));
  const candidate = matching[0] ?? null;
  if (candidate) {
    console.log(
      `newest build of ${VERSION} is ${candidate.attributes.version} (${candidate.attributes.processingState})`
    );
  }
  return candidate;
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

// AI Dictation has no social feed. Apple requires this answer before a version
// can be added to a review submission.
await declareNoSocialMedia(app.id, version.id);

const submissions = await api("GET", `reviewSubmissions?filter[app]=${app.id}&limit=20`);
for (const prior of submissions.data ?? []) {
  console.log(`review submission ${prior.id} state=${prior.attributes.state}`);
  const priorItems = await api(
    "GET",
    `reviewSubmissions/${prior.id}/items?include=appStoreVersion&limit=50`
  );
  for (const item of priorItems.data ?? []) {
    const linkedVersion = item.relationships?.appStoreVersion?.data?.id;
    console.log(`  item ${item.id} appStoreVersion=${linkedVersion ?? "none"} state=${item.attributes?.state}`);
    if (linkedVersion !== version.id) continue;
    if (prior.attributes.state === "READY_FOR_REVIEW") continue;
    try {
      await api("DELETE", `reviewSubmissionItems/${item.id}`);
      console.log(`removed ${VERSION} from submission ${prior.id} (${prior.attributes.state})`);
    } catch (error) {
      if (!String(error.message).includes("already submitted")) throw error;
      await api("DELETE", `reviewSubmissions/${prior.id}`);
      console.log(`canceled submitted review ${prior.id} (${prior.attributes.state})`);
      break;
    }
  }
}

const ready = await api(
  "GET",
  `reviewSubmissions?filter[app]=${app.id}&filter[state]=READY_FOR_REVIEW&limit=10`
);
let submission = ready.data?.[0];
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
