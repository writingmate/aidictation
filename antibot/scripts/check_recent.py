#!/usr/bin/env python3
"""Score today's comments, which aren't in training and aren't guaranteed human.

New accounts should score higher than established ones if the detector finds real bots.
Comments flagged on the labeling page (data/labels.json) are scored when present.
"""
import json, sys
from pathlib import Path

import joblib
import numpy as np

ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(ROOT))

bundle = joblib.load(ROOT / "models/detector.joblib")
pool = json.loads((ROOT / "data/pool.json").read_text())
scores = bundle["model"].predict_proba([r["text"] for r in pool])[:, 1]
strata = np.array([r["stratum"] for r in pool])
for s in ("new", "old"):
    m = strata == s
    print(f"{s}_accounts n={m.sum()} flagged_rate={(scores[m] >= bundle['threshold']).mean():.3f} median_score={np.median(scores[m]):.3f}")

labels_path = ROOT / "data/labels.json"
if labels_path.exists():
    labels = json.loads(labels_path.read_text())
    for name in ("bot", "human", "unsure"):
        s = np.array([sc for r, sc in zip(pool, scores) if labels.get(r["id"]) == name])
        if len(s):
            print(f"your_{name} n={len(s)} flagged_rate={(s >= bundle['threshold']).mean():.3f} scores={np.round(s, 2).tolist()}")
