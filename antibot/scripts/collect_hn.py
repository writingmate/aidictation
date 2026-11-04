#!/usr/bin/env python3
"""Sample recent Hacker News comments into a labeling pool.

New accounts are oversampled because that is where bot comments concentrate;
a random-only sample would give too few positives to learn from. Usernames are
dropped from the output: the model is text-only and labels shouldn't lean on them.
"""
import argparse, concurrent.futures as cf, hashlib, html, json, random, re, time, urllib.request
from pathlib import Path

ALGOLIA = "https://hn.algolia.com/api/v1/search_by_date"
USER = "https://hacker-news.firebaseio.com/v0/user/{}.json"
NEW_ACCOUNT_DAYS = 90
MIN_CHARS, MAX_CHARS = 60, 2000


def get_json(url):
    with urllib.request.urlopen(url, timeout=20) as r:
        return json.load(r)


def clean(comment_html):
    t = re.sub(r"<p>", "\n\n", comment_html or "")
    t = re.sub(r"<a [^>]*href=\"([^\"]*)\"[^>]*>.*?</a>", r"\1", t, flags=re.S)
    t = re.sub(r"<[^>]+>", "", t)
    return html.unescape(t).strip()


def fetch_hits(target):
    hits, before = [], int(time.time())
    while len(hits) < target:
        page = get_json(f"{ALGOLIA}?tags=comment&hitsPerPage=1000&numericFilters=created_at_i<{before}")["hits"]
        if not page:
            break
        hits += page
        before = page[-1]["created_at_i"]
        time.sleep(0.5)
    return hits


def account_created(name):
    try:
        return name, (get_json(USER.format(name)) or {}).get("created")
    except Exception:
        return name, None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--fetch", type=int, default=8000)
    ap.add_argument("--size", type=int, default=600)
    ap.add_argument("--out", default=str(Path(__file__).parent.parent / "data/pool.json"))
    args = ap.parse_args()

    rows, seen = [], set()
    for h in fetch_hits(args.fetch):
        text = clean(h.get("comment_text"))
        if not MIN_CHARS <= len(text) <= MAX_CHARS or text in seen or not h.get("author"):
            continue
        seen.add(text)
        rows.append(h | {"text": text})

    with cf.ThreadPoolExecutor(16) as ex:
        created = dict(ex.map(account_created, {r["author"] for r in rows}))

    now, new, old = time.time(), [], []
    for r in rows:
        c = created.get(r["author"])
        if c is None:
            continue
        (new if now - c < NEW_ACCOUNT_DAYS * 86400 else old).append(r)

    random.seed(7)
    random.shuffle(new)
    random.shuffle(old)
    # Cap per author so one prolific account can't dominate the pool.
    picked, per_author = [], {}
    half = args.size // 2
    for bucket, quota in ((new, half), (old, args.size - half)):
        n = 0
        for r in bucket:
            if n == quota:
                break
            if per_author.get(r["author"], 0) >= 3:
                continue
            per_author[r["author"]] = per_author.get(r["author"], 0) + 1
            picked.append({
                "id": f"hn{r['objectID']}",
                "text": r["text"],
                "context": r.get("story_title") or "",
                "url": f"https://news.ycombinator.com/item?id={r['objectID']}",
                "stratum": "new" if bucket is new else "old",
                "author_group": hashlib.sha256(r["author"].encode()).hexdigest()[:12],
            })
            n += 1
    random.shuffle(picked)
    Path(args.out).write_text(json.dumps(picked, ensure_ascii=False, indent=0))
    print(f"usable={len(rows)} new_account={len(new)} old_account={len(old)} picked={len(picked)} "
          f"new_picked={sum(p['stratum'] == 'new' for p in picked)}")


if __name__ == "__main__":
    main()
