"""
Shared helpers for the GenAI step.

- load_env():      reads the .env file (API key, model name) without extra packages
- GeminiClient:    calls the Gemini REST API and returns parsed JSON
                   (structured output: the model is forced to follow a JSON schema)
- CATEGORIES:      the controlled list of labels (must match sql/05_ai_tables.sql)

Only `requests` and `pandas` are needed - no SDK - so it is easy to see exactly
what is sent to the model and what comes back.
"""
import json
import os
import time
from pathlib import Path

import requests

ROOT = Path(__file__).resolve().parent.parent
WORK = ROOT / "data" / "work"

CATEGORIES = {
    "late_delivery": "arrived after the promised/estimated date, delivery took too long",
    "not_delivered": "never arrived, or marked as delivered but the customer did not receive it",
    "damaged_item": "arrived broken, damaged in transit, or defective / not working on arrival",
    "wrong_item": "received a different product, colour, size or model than ordered",
    "missing_parts": "order incomplete: some items or parts missing from the package",
    "poor_quality": "product works but quality is low, weak material, breaks soon after use",
    "not_as_described": "product does not match the listing photos or description",
    "seller_communication": "seller/store does not respond, bad customer support from the seller",
    "refund_return_issue": "problems with cancellation, return, refund or chargeback",
    "price_value": "too expensive for what it is, freight cost too high",
    "positive_feedback": "satisfied customer, no complaint",
    "other": "anything that does not fit any category above",
}
SENTIMENTS = ["positive", "neutral", "negative"]
SEVERITIES = ["none", "low", "medium", "high"]


def load_env(path=ROOT / ".env"):
    """Minimal .env reader: KEY=value lines, # comments ignored."""
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                os.environ.setdefault(k.strip(), v.strip().strip('"').strip("'"))


class GeminiClient:
    """Tiny wrapper around the Gemini generateContent REST endpoint."""

    URL = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"

    def __init__(self, model=None, api_key=None, requests_per_minute=None):
        load_env()
        self.api_key = api_key or os.getenv("GEMINI_API_KEY")
        self.model = model or os.getenv("GEMINI_MODEL", "gemini-3.5-flash-lite")
        rpm = float(requests_per_minute or os.getenv("GEMINI_RPM", "10"))
        self.min_gap = 60.0 / rpm          # stay under the free-tier requests-per-minute limit
        self._last = 0.0
        if not self.api_key:
            raise SystemExit("GEMINI_API_KEY is missing. Copy .env.example to .env and paste your key "
                             "from https://aistudio.google.com/apikey  (or run with --mode baseline)")

    def generate_json(self, system_prompt, user_prompt, schema, max_retries=6):
        body = {
            "systemInstruction": {"parts": [{"text": system_prompt}]},
            "contents": [{"role": "user", "parts": [{"text": user_prompt}]}],
            "generationConfig": {
                "responseMimeType": "application/json",   # structured output ...
                "responseSchema": schema,                  # ... that must match this schema
            },
        }
        headers = {"x-goog-api-key": self.api_key, "Content-Type": "application/json"}
        for attempt in range(max_retries):
            wait = self.min_gap - (time.time() - self._last)
            if wait > 0:
                time.sleep(wait)
            self._last = time.time()
            try:
                r = requests.post(self.URL.format(model=self.model), headers=headers,
                                  data=json.dumps(body), timeout=120)
            except requests.RequestException as e:
                print(f"  network error ({e}); retrying")
                time.sleep(2 ** attempt)
                continue
            if r.status_code == 200:
                data = r.json()
                try:
                    parts = data["candidates"][0]["content"]["parts"]
                    # join all answer parts; skip "thought" parts some models can return
                    text = "".join(p.get("text", "") for p in parts if not p.get("thought"))
                    usage = data.get("usageMetadata", {})
                    return json.loads(text), usage
                except (KeyError, IndexError, json.JSONDecodeError):
                    print(f"  unexpected response, retrying: {str(data)[:300]}")
            elif r.status_code in (429, 500, 502, 503, 504):
                # 429 = rate limit / quota. Back off exponentially: 2, 4, 8, 16 ... seconds
                print(f"  HTTP {r.status_code} (rate limit or server busy); waiting {2 ** (attempt + 1)}s")
                time.sleep(2 ** (attempt + 1))
            else:
                raise SystemExit(f"Gemini API error {r.status_code}: {r.text[:500]}")
        raise RuntimeError("Gemini call failed after retries")
