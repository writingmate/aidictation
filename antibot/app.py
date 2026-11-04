"""HTTP API for the comment bot detector. Requires ANTIBOT_API_KEY to be set."""
import os
import secrets
from pathlib import Path
from typing import Annotated

import joblib
from fastapi import Depends, FastAPI, Header, HTTPException
from pydantic import BaseModel, Field, StringConstraints

MODEL_PATH = Path(os.environ.get("ANTIBOT_MODEL", Path(__file__).parent / "models/detector.joblib"))
API_KEY = os.environ["ANTIBOT_API_KEY"]
MAX_BATCH = 100
MAX_CHARS = 10000
MIN_RELIABLE_CHARS = 60

bundle = joblib.load(MODEL_PATH)
app = FastAPI(title="Antibot comment detector")


def require_key(authorization: str = Header(default="")):
    if not secrets.compare_digest(authorization.encode(), f"Bearer {API_KEY}".encode()):
        raise HTTPException(status_code=401, detail="Invalid API key")


class DetectRequest(BaseModel):
    comments: list[Annotated[str, StringConstraints(min_length=1, max_length=MAX_CHARS)]] = Field(min_length=1, max_length=MAX_BATCH)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/v1/detect", dependencies=[Depends(require_key)])
def detect(req: DetectRequest):
    scores = bundle["model"].predict_proba(req.comments)[:, 1]
    return {
        "threshold": bundle["threshold"],
        "results": [{
            "bot_score": round(float(s), 4),
            "is_bot": bool(s >= bundle["threshold"]),
            "too_short_to_trust": len(c) < MIN_RELIABLE_CHARS,
        } for c, s in zip(req.comments, scores)],
    }
