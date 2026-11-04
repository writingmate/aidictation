#!/usr/bin/env python3
"""Write generation task files: one comment per line of thread, target length and style."""
import json, random
from pathlib import Path

DATA = Path(__file__).parent.parent / "data"
STYLES = {
    0: "natural LLM voice: helpful, balanced, well organized",
    1: "knowledgeable commenter sharing an informed opinion",
    2: "casual and conversational, contractions, an occasional fragment",
    3: "short personal anecdote related to the thread, as if it happened to you",
    4: "politely push back on the thread's premise and give a reason",
    5: "terse, lowercase, loose punctuation, like typing on a phone",
}
PLAN = {"haiku": 240, "sonnet": 240, "opus": 150, "fable": 150,
        "gpt": 60, "gemini": 60, "deepseek": 60, "grok": 60}

humans = [json.loads(l) for l in (DATA / "human.jsonl").read_text().splitlines()]
random.seed(17)
gen = DATA / "gen"
gen.mkdir(exist_ok=True)
for name, n in PLAN.items():
    rows = []
    for i, h in enumerate(random.sample(humans, n)):
        rows.append({"id": f"{name}-{i}", "style": i % 6, "chars": len(h["text"]), "thread": h["context"]})
    (gen / f"tasks_{name}.jsonl").write_text("".join(json.dumps(r, ensure_ascii=False) + "\n" for r in rows))
(gen / "styles.json").write_text(json.dumps(STYLES, indent=1))
print({k: v for k, v in PLAN.items()})
