#!/usr/bin/env python3
"""Collect HN comments from 2016-2020, before LLMs could write convincing comments.

These are the human class. Their threads are reused for LLM generation so topic
and era can't separate the classes.
"""
import argparse, json, random, time
from pathlib import Path

from collect_hn import ALGOLIA, MAX_CHARS, MIN_CHARS, clean, get_json

START, END = 1451606400, 1609459200  # 2016-01-01 .. 2021-01-01


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=2000)
    ap.add_argument("--out", default=str(Path(__file__).parent.parent / "data/human.jsonl"))
    args = ap.parse_args()
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)

    random.seed(11)
    rows, seen = [], set()
    while len(rows) < args.n:
        at = random.randint(START, END)
        for h in get_json(f"{ALGOLIA}?tags=comment&hitsPerPage=100&numericFilters=created_at_i<{at}")["hits"]:
            text = clean(h.get("comment_text"))
            if not MIN_CHARS <= len(text) <= MAX_CHARS or text in seen or not h.get("story_title"):
                continue
            seen.add(text)
            rows.append({"text": text, "label": "human", "source": "hn_2016_2020", "context": h["story_title"]})
        time.sleep(0.3)
    Path(args.out).write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows[:args.n]))


if __name__ == "__main__":
    main()
