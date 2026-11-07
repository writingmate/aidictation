#!/usr/bin/env python3
"""Fetch HC3 reddit_eli5 (ChatGPT and human answers to the same forum questions) as a non-Claude test set."""
import json, time, urllib.parse, urllib.request
from pathlib import Path

OUT = Path(__file__).parent.parent / "data/hc3.jsonl"
DATASET = "Hello-SimpleAI/HC3"
PAGES = 6


def fetch(endpoint, **params):
    q = urllib.parse.urlencode({"dataset": DATASET, **params})
    for attempt in range(4):
        try:
            with urllib.request.urlopen(f"https://datasets-server.huggingface.co/{endpoint}?{q}", timeout=60) as r:
                return json.load(r)
        except Exception as e:
            print("retry", attempt, repr(e)[:120], flush=True)
            time.sleep(5 * (attempt + 1))
    raise SystemExit(f"{endpoint} unavailable")


splits = fetch("splits")["splits"]
print([(s["config"], s["split"]) for s in splits])
config = next(s for s in splits if "eli5" in s["config"])
OUT.parent.mkdir(parents=True, exist_ok=True)
with OUT.open("w") as f:
    for page in range(PAGES):
        rows = fetch("rows", config=config["config"], split=config["split"], offset=page * 100, length=100)["rows"]
        for x in rows:
            r = x["row"]
            for label, key in (("human", "human_answers"), ("bot", "chatgpt_answers")):
                for text in (r.get(key) or [])[:1]:
                    f.write(json.dumps({"text": text.strip(), "label": label, "question": r.get("question", "")}, ensure_ascii=False) + "\n")
        time.sleep(0.5)
