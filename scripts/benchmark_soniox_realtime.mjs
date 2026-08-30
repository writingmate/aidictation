#!/usr/bin/env node

import { execFileSync, spawnSync } from "node:child_process";
import { performance } from "node:perf_hooks";
import { basename, join, resolve } from "node:path";
import { readdirSync } from "node:fs";

const defaultFixturePrefixes = [
  "F39D1AB6",
  "CA599490",
  "C5CE3D84",
  "41B8079B",
  "F303353E",
  "C8609A87",
];
const defaultRecordingsDirectory = join(
  process.env.HOME ?? "",
  "Library/Application Support/WhisperMate/AudioProcessing/Recordings",
);
const defaultSecretsPath = resolve(
  "Whishpermate/Whispermate/Secrets.plist",
);
const sonioxSocketURL = "wss://stt-rt.soniox.com/transcribe-websocket";
const pcmSampleRate = 24_000;
const pcmBytesPerSecond = pcmSampleRate * 2;
const chunkMilliseconds = 20;
const chunkBytes = (pcmBytesPerSecond * chunkMilliseconds) / 1_000;

function argumentValue(name, fallback) {
  const index = process.argv.indexOf(name);
  return index === -1 ? fallback : process.argv[index + 1];
}

function readPlistValue(path, key) {
  return execFileSync(
    "/usr/bin/plutil",
    ["-extract", key, "raw", "-o", "-", path],
    { encoding: "utf8", stdio: ["ignore", "pipe", "ignore"] },
  ).trim();
}

function fixturePaths(directory) {
  const names = readdirSync(directory);
  return defaultFixturePrefixes.map((prefix) => {
    const name = names.find((candidate) => candidate.startsWith(prefix));
    if (!name) throw new Error(`Missing fixture ${prefix} in ${directory}`);
    return join(directory, name);
  });
}

function decodePCM(path) {
  const result = spawnSync(
    "/opt/homebrew/bin/ffmpeg",
    [
      "-hide_banner",
      "-loglevel",
      "error",
      "-i",
      path,
      "-f",
      "s16le",
      "-acodec",
      "pcm_s16le",
      "-ac",
      "1",
      "-ar",
      String(pcmSampleRate),
      "pipe:1",
    ],
    { encoding: null, maxBuffer: 32 * 1024 * 1024 },
  );
  if (result.status !== 0) {
    throw new Error(`Could not decode ${basename(path)}`);
  }
  return result.stdout;
}

function percentile(values, fraction) {
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * fraction) - 1)];
}

function sleep(milliseconds) {
  return new Promise((resolveSleep) => setTimeout(resolveSleep, milliseconds));
}

async function temporarySonioxKey({ endpoint, authorization }) {
  const response = await fetch(endpoint, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${authorization}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({
      model: "stt-rt-v5",
      languages: ["en", "ru"],
    }),
  });
  const body = await response.json();
  if (!response.ok || typeof body.value !== "string") {
    throw new Error(`Temporary Soniox key request failed with HTTP ${response.status}`);
  }
  return {
    value: body.value,
    socketURL:
      typeof body.websocket_url === "string"
        ? body.websocket_url
        : sonioxSocketURL,
  };
}

async function sonioxRealtime({ pcm, endpoint, authorization }) {
  const temporaryKey = await temporarySonioxKey({ endpoint, authorization });
  const socket = new WebSocket(temporaryKey.socketURL);
  let finalized = "";
  let provisional = "";
  let keyUpAt = 0;

  const completion = new Promise((resolveCompletion, rejectCompletion) => {
    const timeout = setTimeout(() => {
      socket.close();
      rejectCompletion(new Error("Soniox finalization timed out"));
    }, 10_000);

    socket.addEventListener("message", (event) => {
      let payload;
      try {
        payload = JSON.parse(String(event.data));
      } catch {
        clearTimeout(timeout);
        rejectCompletion(new Error("Soniox returned invalid JSON"));
        return;
      }
      if (typeof payload.error_type === "string") {
        clearTimeout(timeout);
        rejectCompletion(new Error(`Soniox error ${payload.error_type}`));
        return;
      }

      provisional = "";
      let didFinalize = payload.finished === true;
      for (const token of Array.isArray(payload.tokens) ? payload.tokens : []) {
        if (token?.text === "<fin>") {
          didFinalize ||= token.is_final === true;
        } else if (token?.is_final === true && typeof token.text === "string") {
          finalized += token.text;
        } else if (typeof token?.text === "string") {
          provisional += token.text;
        }
      }
      if (didFinalize) {
        clearTimeout(timeout);
        const completedAt = performance.now();
        socket.close();
        resolveCompletion({
          raw: (finalized + provisional).trim(),
          keyUpToFinalMs: Math.round(completedAt - keyUpAt),
        });
      }
    });
    socket.addEventListener("error", () => {
      clearTimeout(timeout);
      rejectCompletion(new Error("Soniox WebSocket failed"));
    });
  });

  await new Promise((resolveOpen, rejectOpen) => {
    socket.addEventListener("open", resolveOpen, { once: true });
    socket.addEventListener("error", rejectOpen, { once: true });
  });
  socket.send(JSON.stringify({
    api_key: temporaryKey.value,
    model: "stt-rt-v5",
    audio_format: "pcm_s16le",
    sample_rate: pcmSampleRate,
    num_channels: 1,
    language_hints: ["en", "ru"],
    enable_language_identification: true,
  }));

  for (let offset = 0; offset < pcm.length; offset += chunkBytes) {
    socket.send(pcm.subarray(offset, Math.min(offset + chunkBytes, pcm.length)));
    await sleep(chunkMilliseconds);
  }
  keyUpAt = performance.now();
  socket.send(Buffer.alloc(pcmBytesPerSecond / 5));
  socket.send(JSON.stringify({ type: "finalize" }));
  return completion;
}

async function currentBatch({ path, endpoint, authorization }) {
  const audio = await import("node:fs/promises").then(({ readFile }) => readFile(path));
  const form = new FormData();
  form.append("file", new Blob([audio]), basename(path));
  form.append("model", "openai/gpt-transcribe");
  form.append("post_processing", "false");
  const startedAt = performance.now();
  const response = await fetch(endpoint, {
    method: "POST",
    headers: { Authorization: `Bearer ${authorization}` },
    body: form,
  });
  const raw = await response.text();
  if (!response.ok) {
    throw new Error(`Current provider failed with HTTP ${response.status}`);
  }
  return {
    raw: raw.trim(),
    keyUpToFinalMs: Math.round(performance.now() - startedAt),
    upstreamMs: Number(response.headers.get("x-aidictation-stt-ms")) || null,
    provider: response.headers.get("x-aidictation-provider") ?? "unknown",
  };
}

async function main() {
  const secretsPath = resolve(argumentValue("--secrets", defaultSecretsPath));
  const recordingsDirectory = resolve(
    argumentValue("--recordings", defaultRecordingsDirectory),
  );
  const authorization = readPlistValue(secretsPath, "CustomTranscriptionKey");
  const batchEndpoint = readPlistValue(secretsPath, "CustomTranscriptionEndpoint");
  const realtimeEndpoint = new URL(
    "/api/openai/v1/realtime/client_secrets",
    batchEndpoint,
  ).toString();
  const rows = [];

  for (const path of fixturePaths(recordingsDirectory)) {
    const pcm = decodePCM(path);
    const [current, soniox] = await Promise.all([
      currentBatch({ path, endpoint: batchEndpoint, authorization }),
      sonioxRealtime({ pcm, endpoint: realtimeEndpoint, authorization }),
    ]);
    const row = { fixture: basename(path).slice(0, 8), current, soniox };
    rows.push(row);
    console.log(JSON.stringify(row));
  }

  const currentLatencies = rows.map((row) => row.current.keyUpToFinalMs);
  const sonioxLatencies = rows.map((row) => row.soniox.keyUpToFinalMs);
  console.log(JSON.stringify({
    summary: {
      count: rows.length,
      current: {
        p50: percentile(currentLatencies, 0.5),
        p90: percentile(currentLatencies, 0.9),
      },
      soniox: {
        p50: percentile(sonioxLatencies, 0.5),
        p90: percentile(sonioxLatencies, 0.9),
      },
    },
  }));
}

main().catch((error) => {
  console.error(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
