#!/usr/bin/env node

const childProcess = require("child_process");
const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");

const appBundleId = "com.whispermate.ios";
const keyboardBundleId = "com.whispermate.ios.keyboard";

function requiredEnv(name) {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

function run(command, args, options = {}) {
  childProcess.execFileSync(command, args, {
    stdio: options.stdio || "inherit",
    ...options
  });
}

function output(command, args, options = {}) {
  return childProcess.execFileSync(command, args, {
    encoding: "utf8",
    stdio: ["ignore", "pipe", "inherit"],
    ...options
  }).trim();
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

async function request(method, route, body) {
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
    throw new Error(`App Store Connect API ${method} ${route} failed (${response.status}): ${text}`);
  }
  return json;
}

async function bundleIdFor(identifier) {
  const response = await request("GET", `/v1/bundleIds?filter[identifier]=${encodeURIComponent(identifier)}&limit=1`);
  const bundle = response.data && response.data[0];
  if (!bundle) {
    throw new Error(`No Apple Developer bundle ID found for ${identifier}`);
  }
  return bundle.id;
}

async function createCertificate(csrContent) {
  const response = await request("POST", "/v1/certificates", {
    data: {
      type: "certificates",
      attributes: {
        certificateType: "IOS_DISTRIBUTION",
        csrContent
      }
    }
  });
  return {
    id: response.data.id,
    content: response.data.attributes.certificateContent
  };
}

async function createProfile({ name, bundleId, certificateId }) {
  const response = await request("POST", "/v1/profiles", {
    data: {
      type: "profiles",
      attributes: {
        name,
        profileType: "IOS_APP_STORE"
      },
      relationships: {
        bundleId: {
          data: {
            type: "bundleIds",
            id: bundleId
          }
        },
        certificates: {
          data: [
            {
              type: "certificates",
              id: certificateId
            }
          ]
        }
      }
    }
  });

  return {
    uuid: response.data.attributes.uuid,
    name: response.data.attributes.name,
    content: response.data.attributes.profileContent
  };
}

function installProfile(profile) {
  const dir = path.join(os.homedir(), "Library", "MobileDevice", "Provisioning Profiles");
  fs.mkdirSync(dir, { recursive: true });
  const profilePath = path.join(dir, `${profile.uuid}.mobileprovision`);
  fs.writeFileSync(profilePath, Buffer.from(profile.content, "base64"));
  console.log(`Installed provisioning profile ${profile.name} (${profile.uuid})`);
}

function appendGitHubEnv(values) {
  const envPath = requiredEnv("GITHUB_ENV");
  const lines = Object.entries(values).map(([key, value]) => `${key}=${value}`);
  fs.appendFileSync(envPath, `${lines.join("\n")}\n`);
}

async function main() {
  const workDir = fs.mkdtempSync(path.join(os.tmpdir(), "whispermate-ios-signing-"));
  const keychainPassword = crypto.randomBytes(24).toString("hex");
  const keychainPath = path.join(workDir, "ios-signing.keychain-db");
  const privateKeyPath = path.join(workDir, "distribution.key");
  const csrPath = path.join(workDir, "distribution.csr");
  const certificateDerPath = path.join(workDir, "distribution.cer");
  const certificatePemPath = path.join(workDir, "distribution.pem");
  const p12Path = path.join(workDir, "distribution.p12");
  const p12Password = crypto.randomBytes(24).toString("hex");

  run("security", ["create-keychain", "-p", keychainPassword, keychainPath]);
  run("security", ["set-keychain-settings", "-lut", "21600", keychainPath]);
  run("security", ["unlock-keychain", "-p", keychainPassword, keychainPath]);
  const existingKeychains = output("security", ["list-keychains", "-d", "user"])
    .split("\n")
    .map((line) => line.trim().replace(/^"|"$/g, ""))
    .filter(Boolean);
  run("security", ["list-keychains", "-d", "user", "-s", keychainPath, ...existingKeychains]);
  run("security", ["default-keychain", "-s", keychainPath]);

  run("openssl", ["genrsa", "-out", privateKeyPath, "2048"]);
  run("openssl", ["req", "-new", "-key", privateKeyPath, "-out", csrPath, "-subj", "/CN=WhisperMate iOS CI"]);
  const csrContent = fs.readFileSync(csrPath, "utf8");
  const certificate = await createCertificate(csrContent);
  fs.writeFileSync(certificateDerPath, Buffer.from(certificate.content, "base64"));
  run("openssl", ["x509", "-inform", "DER", "-in", certificateDerPath, "-out", certificatePemPath]);
  run("openssl", [
    "pkcs12",
    "-export",
    "-inkey",
    privateKeyPath,
    "-in",
    certificatePemPath,
    "-out",
    p12Path,
    "-legacy",
    "-passout",
    `pass:${p12Password}`
  ]);
  run("security", ["import", p12Path, "-k", keychainPath, "-P", p12Password, "-T", "/usr/bin/codesign", "-T", "/usr/bin/security"]);
  run("security", ["set-key-partition-list", "-S", "apple-tool:,apple:", "-s", "-k", keychainPassword, keychainPath]);

  const runId = process.env.GITHUB_RUN_ID || Date.now().toString();
  const appProfile = await createProfile({
    name: `WhisperMate iOS App Store CI ${runId}`,
    bundleId: await bundleIdFor(appBundleId),
    certificateId: certificate.id
  });
  const keyboardProfile = await createProfile({
    name: `WhisperMate Keyboard App Store CI ${runId}`,
    bundleId: await bundleIdFor(keyboardBundleId),
    certificateId: certificate.id
  });

  installProfile(appProfile);
  installProfile(keyboardProfile);

  appendGitHubEnv({
    IOS_APPSTORE_PROFILE_NAME: appProfile.uuid,
    IOS_KEYBOARD_APPSTORE_PROFILE_NAME: keyboardProfile.uuid
  });
}

main().catch((error) => {
  console.error(error.message);
  process.exit(1);
});
