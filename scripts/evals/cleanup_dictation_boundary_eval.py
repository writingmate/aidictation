#!/usr/bin/env python3
"""Check that cleanup transcribes dictated requests instead of performing them.

Builds the default dictation cleanup prompt the same way
TranscriptionCleanupPrompt.systemPrompt does, from the shared policy files and
the Swift header, then replays each case against an OpenAI-compatible chat
endpoint. Pass --ref to build the prompt from another git ref (for example
origin/main) and compare it against the working tree.

A run passes when its words equal the source words, ignoring case,
punctuation, and standalone fillers. An empty response is reported separately:
the apps replace it with the raw transcript, so it is not a failure.

Needs network access and an API key, so it is not part of CI.
"""

import argparse
import concurrent.futures
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CASES = Path(__file__).resolve().parent / "cleanup_dictation_boundary_cases.json"
SWIFT_PROMPT = "Whishpermate/WhisperMateShared/Networking/TranscriptionCleanupPrompt.swift"
CLEANUP_POLICY = "scripts/transcription_cleanup_policy.txt"
PARAGRAPH_POLICY = "scripts/transcription_paragraph_policy.txt"
# Mirrors TranscriptionCleanupPrompt.screenContextCharacterLimit.
SCREEN_CONTEXT_LIMIT = 1_200
FILLERS = {"um", "uh", "uhm", "umm", "er", "erm", "ah", "hmm", "ugh"}


def read_source(path, ref):
    if ref is None:
        return (ROOT / path).read_text()
    return subprocess.run(
        ["git", "-C", str(ROOT), "show", f"{ref}:{path}"],
        check=True, capture_output=True, text=True,
    ).stdout


def prompt_header(swift_source):
    opening = re.search(r':\s*"(Clean <transcription>\.)"', swift_source)
    rules = re.search(r'prompt \+= "( XML entities[^"]*)"', swift_source)
    if not opening or not rules:
        raise SystemExit("could not locate the cleanup prompt header in " + SWIFT_PROMPT)
    return opening.group(1) + rules.group(1)


def closing_reminder(swift_source):
    """The line TranscriptionCleanupPrompt.userMessage appends after the source.

    Older refs have no reminder, so the eval sends exactly what each ref sent.
    """
    match = re.search(
        r'static let transcriptionClosingReminder =\s*\n?\s*"([^"]*)"', swift_source
    )
    return match.group(1) if match else None


def user_message(ref, source):
    message = f"<transcription>\n{escape(source)}\n</transcription>"
    reminder = closing_reminder(read_source(SWIFT_PROMPT, ref))
    if reminder:
        message += "\n\n" + reminder
    return message


def escape(value):
    return value.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def system_prompt(ref, app_context, screen_context):
    prompt = prompt_header(read_source(SWIFT_PROMPT, ref))
    prompt += "\n\n" + read_source(CLEANUP_POLICY, ref).strip()
    prompt += "\n\n" + read_source(PARAGRAPH_POLICY, ref).strip()
    prompt += f"\n\n<app_context>\n{escape(app_context)}\n</app_context>"
    if screen_context:
        capped = screen_context.strip()[:SCREEN_CONTEXT_LIMIT]
        prompt += f"\n\n<screen_context>\n{escape(capped)}\n</screen_context>"
    return prompt


def complete(args, system, user):
    body = {
        "model": args.model,
        "temperature": 0,
        "max_tokens": 1000,
        "messages": [
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
    }
    request = urllib.request.Request(
        args.base_url.rstrip("/") + "/chat/completions",
        json.dumps(body).encode(),
        {
            "Authorization": "Bearer " + os.environ[args.api_key_env],
            "Content-Type": "application/json",
            "User-Agent": "aidictation-cleanup-eval",
        },
    )
    error = None
    for attempt in range(6):
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                return json.load(response)["choices"][0]["message"].get("content") or ""
        except urllib.error.HTTPError as caught:
            error = caught
            if caught.code != 429:
                raise RuntimeError(f"request failed: {caught}") from caught
            # Shared keys sit on tight token-per-minute limits; wait them out.
            retry_after = caught.headers.get("retry-after")
            delay = float(retry_after) if retry_after and retry_after.replace(".", "", 1).isdigit() else 2.0 ** attempt
            time.sleep(min(delay + 1, 90))
        except Exception as caught:  # noqa: BLE001 - retried, then reported
            error = caught
            time.sleep(2.0 ** attempt)
    raise RuntimeError(f"request failed: {error}")


def words(text):
    return [word for word in re.findall(r"[a-z0-9']+", text.lower()) if word not in FILLERS]


REFUSAL_OPENERS = re.compile(
    r"^(i'?m sorry|i am sorry|sorry|apologies|unfortunately|i apologi[sz]e|as an ai|"
    r"i (can'?t|cannot|can not|won'?t|will not|am unable|'?m unable|am not able|'?m not able))\b"
)


def classify_failure(output):
    """Label a failing output so refusals and fulfilled requests are visible."""
    head = re.sub(r"^[\s>*`\"'_-]+", "", output.strip().lower())
    if REFUSAL_OPENERS.match(head):
        return "refusal"
    return "rewrote"


def run_variant(args, label, ref, suite):
    prompts = {
        False: system_prompt(ref, suite["app_context"], None),
        True: system_prompt(ref, suite["app_context"], suite["screen_context"]),
    }
    jobs = [(case, index) for case in suite["cases"] for index in range(args.runs)]
    tallies = {
        case["id"]: {"pass": 0, "empty": 0, "refusal": 0, "fail": []}
        for case in suite["cases"]
    }
    with concurrent.futures.ThreadPoolExecutor(args.concurrency) as pool:
        futures = {
            pool.submit(
                complete,
                args,
                prompts[case.get("use_screen_context", False)],
                user_message(ref, case["source"]),
            ): case
            for case, _ in jobs
        }
        for future in concurrent.futures.as_completed(futures):
            case = futures[future]
            output = future.result()
            tally = tallies[case["id"]]
            if not output.strip():
                tally["empty"] += 1
            elif words(output) == words(case["source"]):
                tally["pass"] += 1
            else:
                if classify_failure(output) == "refusal":
                    tally["refusal"] += 1
                tally["fail"].append(output)

    print(f"\n{label}")
    failures = 0
    for case_id, tally in tallies.items():
        failures += len(tally["fail"])
        empty = f"  empty {tally['empty']}" if tally["empty"] else ""
        refusal = f"  refusal {tally['refusal']}" if tally["refusal"] else ""
        print(
            f"  {case_id:40} pass {tally['pass']}/{args.runs}  fail {len(tally['fail'])}{refusal}{empty}"
        )
        for output in tally["fail"][:args.show]:
            print("      " + output.replace("\n", " | ")[:200])
    return failures


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--runs", type=int, default=10, help="replays per case")
    parser.add_argument("--ref", help="also evaluate the prompt at this git ref, e.g. origin/main")
    parser.add_argument("--model", default="openai/gpt-oss-20b")
    parser.add_argument("--base-url", default="https://api.groq.com/openai/v1")
    parser.add_argument("--api-key-env", default="GROQ_API_KEY")
    parser.add_argument("--concurrency", type=int, default=8)
    parser.add_argument("--show", type=int, default=1, help="failing outputs to print per case")
    args = parser.parse_args()
    if not os.environ.get(args.api_key_env):
        raise SystemExit(f"set {args.api_key_env}")

    suite = json.loads(CASES.read_text())
    if args.ref:
        run_variant(args, f"{args.ref} (reference)", args.ref, suite)
    failures = run_variant(args, "working tree", None, suite)
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
