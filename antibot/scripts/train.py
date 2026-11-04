#!/usr/bin/env python3
"""Train the detector and report held-out metrics.

human: pre-LLM HN comments and HC3 forum answers. bot: Claude comments on the same HN
threads and ChatGPT answers to the same HC3 questions, so topic can't separate the classes.

Three tests, all grouped by thread so topic can't leak across a split:
- cross-validation over everything;
- leave one Claude model out;
- leave one LLM family out, the closest thing here to a detector meeting a new LLM.

The threshold comes from out-of-fold human scores at a target false-positive rate,
because precision depends on a platform's bot rate, which we don't know.
"""
import argparse, glob, hashlib, json, sys
from pathlib import Path

import joblib
import numpy as np
from sklearn.feature_extraction.text import TfidfVectorizer
from sklearn.linear_model import LogisticRegression
from sklearn.metrics import average_precision_score, roc_auc_score
from sklearn.model_selection import StratifiedGroupKFold
from sklearn.pipeline import FeatureUnion, make_pipeline

ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(ROOT))
from textnorm import detokenize, normalize

DATA = ROOT / "data"
TARGET_FPR = 0.01
MIN_CHARS, MAX_CHARS = 60, 2000
CLAUDE = ["fable", "haiku", "opus", "sonnet"]


def build_model():
    features = FeatureUnion([
        ("word", TfidfVectorizer(preprocessor=normalize, ngram_range=(1, 2), min_df=3, sublinear_tf=True, max_features=50000)),
        ("char", TfidfVectorizer(preprocessor=normalize, analyzer="char_wb", ngram_range=(2, 5), min_df=3, sublinear_tf=True, max_features=100000)),
    ])
    return make_pipeline(features, LogisticRegression(C=3, class_weight="balanced", max_iter=3000))


def thread_group(title):
    return hashlib.sha256(title.encode()).hexdigest()[:12]


def load_rows():
    rows = [json.loads(l) | {"family": "hn"} for l in (DATA / "human.jsonl").read_text().splitlines()]
    for tasks_path in sorted(glob.glob(str(DATA / "gen/tasks_*.jsonl"))):
        name = Path(tasks_path).stem.removeprefix("tasks_")
        tasks = {t["id"]: t for t in map(json.loads, Path(tasks_path).read_text().splitlines())}
        for part in sorted(glob.glob(str(DATA / f"gen/output_{name}.part*.json"))):
            for o in json.loads(Path(part).read_text()):
                t = tasks.get(o.get("id"))
                if t and isinstance(o.get("text"), str) and o["text"].strip():
                    rows.append({"text": o["text"].strip(), "label": "bot", "source": name, "family": "hn", "context": t["thread"]})
    for r in map(json.loads, (DATA / "hc3.jsonl").read_text().splitlines()):
        text = detokenize(r["text"]) if r["label"] == "human" else r["text"]
        if MIN_CHARS <= len(text) <= MAX_CHARS:
            rows.append({"text": text, "label": r["label"], "family": "hc3", "context": r["question"],
                         "source": "chatgpt" if r["label"] == "bot" else "hc3_human"})
    return rows


def evaluate(train_mask, bots, humans, threshold, X, y):
    model = build_model().fit(X[train_mask], y[train_mask])
    h, b = model.predict_proba(X[humans])[:, 1], model.predict_proba(X[bots])[:, 1]
    return {
        "n_bot": int(bots.sum()), "n_human": int(humans.sum()),
        "roc_auc": round(roc_auc_score(np.r_[np.zeros(len(h)), np.ones(len(b))], np.r_[h, b]), 4),
        "recall_at_threshold": round(float((b >= threshold).mean()), 3),
        "fpr_at_threshold": round(float((h >= threshold).mean()), 3),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=str(ROOT / "models/detector.joblib"))
    args = ap.parse_args()

    rows = load_rows()
    X = np.array([r["text"] for r in rows], dtype=object)
    y = np.array([r["label"] == "bot" for r in rows], dtype=int)
    groups = np.array([thread_group(r["context"]) for r in rows])
    sources = np.array([r["source"] for r in rows])
    family = np.array([r["family"] for r in rows])
    print({s: int((sources == s).sum()) for s in sorted(set(sources))})

    scores = np.zeros(len(y))
    for train, test in StratifiedGroupKFold(5, shuffle=True, random_state=7).split(X, y, groups):
        scores[test] = build_model().fit(X[train], y[train]).predict_proba(X[test])[:, 1]
    threshold = float(np.quantile(scores[y == 0], 1 - TARGET_FPR))

    metrics = {
        "n_human": int((y == 0).sum()), "n_bot": int(y.sum()),
        "cv_roc_auc": round(roc_auc_score(y, scores), 4),
        "cv_pr_auc": round(average_precision_score(y, scores), 4),
        "threshold": round(threshold, 4),
        "cv_fpr": round(float((scores[y == 0] >= threshold).mean()), 4),
        "cv_recall": round(float((scores[y == 1] >= threshold).mean()), 4),
        "cv_recall_by_source": {s: round(float((scores[sources == s] >= threshold).mean()), 3)
                                for s in sorted(set(sources[y == 1]))},
        "cv_fpr_by_source": {s: round(float((scores[sources == s] >= threshold).mean()), 3)
                             for s in sorted(set(sources[y == 0]))},
    }

    metrics["leave_one_claude_model_out"] = {}
    for held in CLAUDE:
        is_held = sources == held
        in_threads = np.isin(groups, list(set(groups[is_held])))
        metrics["leave_one_claude_model_out"][held] = evaluate(
            ~is_held & ~in_threads, is_held, (y == 0) & in_threads, threshold, X, y)

    # A family's bots are withheld. Its humans stay in training only when they come from
    # a different forum, and the test humans are always the withheld forum's own.
    claude, chatgpt = np.isin(sources, CLAUDE), sources == "chatgpt"
    metrics["leave_one_family_out"] = {
        "claude_unseen": evaluate(family == "hc3", claude, sources == "hn_2016_2020", threshold, X, y),
        "chatgpt_unseen": evaluate(family == "hn", chatgpt, sources == "hc3_human", threshold, X, y),
    }

    print(json.dumps(metrics, indent=2))
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    joblib.dump({"model": build_model().fit(X, y), "threshold": threshold, "metrics": metrics}, args.out, compress=3)
    (DATA / "metrics.json").write_text(json.dumps(metrics, indent=2))
    print(f"saved {args.out} ({Path(args.out).stat().st_size / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
