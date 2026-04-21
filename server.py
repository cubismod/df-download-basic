# /// script
# requires-python = ">=3.11"
# dependencies = [
#     "fastapi",
#     "uvicorn",
# ]
# ///

from __future__ import annotations

import os
from pathlib import Path
from threading import Lock
from urllib.parse import parse_qsl, urlencode, urlsplit, urlunsplit

import uvicorn
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel


app = FastAPI()
queue_lock = Lock()

QUEUE_FILE = Path(os.environ.get("DF_QUEUE_FILE", Path.home() / ".df_queue")).expanduser()
VOLATILE_QUERY_PARAMS = {
    "signature",
    "token",
    "auth",
    "session",
    "sid",
    "expires",
    "exp",
    "timestamp",
    "ts",
    "nonce",
}


class AddRequest(BaseModel):
    url: str


def normalize_url(url: str) -> str:
    parts = urlsplit(url)
    kept_query = [
        (key, value)
        for key, value in parse_qsl(parts.query, keep_blank_values=True)
        if key not in VOLATILE_QUERY_PARAMS
    ]
    kept_query.sort()
    return urlunsplit((parts.scheme, parts.netloc, parts.path, urlencode(kept_query), ""))


@app.post("/add")
def add_video(payload: AddRequest) -> dict[str, object]:
    url = payload.url.strip()
    if not url.startswith(("http://", "https://")):
        raise HTTPException(status_code=400, detail="URL must start with http:// or https://")

    normalized_url = normalize_url(url)

    with queue_lock:
        existing_urls: list[str] = []
        if QUEUE_FILE.exists():
            existing_urls = [
                line.strip()
                for line in QUEUE_FILE.read_text().splitlines()
                if line.strip()
            ]
            for queued_url in existing_urls:
                if normalize_url(queued_url) == normalized_url:
                    return {"ok": True, "queued": False, "reason": "duplicate"}

        QUEUE_FILE.parent.mkdir(parents=True, exist_ok=True)
        with QUEUE_FILE.open("a", encoding="utf-8") as handle:
            handle.write(f"{url}\n")

        return {
            "ok": True,
            "queued": True,
            "queue_file": str(QUEUE_FILE),
            "queue_length": len(existing_urls) + 1,
        }


if __name__ == "__main__":
    uvicorn.run(app, host="0.0.0.0", port=int(os.environ.get("PORT", "8000")))
