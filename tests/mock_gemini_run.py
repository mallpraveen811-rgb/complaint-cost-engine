"""
OFFLINE TEST of the LLM code path. Replaces the real HTTP call with a fake Gemini
response so the parsing, validation, resume and CSV logic can be tested without an
API key. The fake "model" answers from the synthetic sample's hidden truth with ~8%
deliberate mistakes. Output is labelled model='MOCK' - never use it as a result.

  python tests/mock_gemini_run.py
"""
import json
import os
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "genai"))
os.environ["GEMINI_API_KEY"] = "mock-key"
os.environ["GEMINI_MODEL"] = "MOCK"
os.environ["GEMINI_RPM"] = "100000"

import pandas as pd
import requests

import common

random.seed(1)
truth = pd.read_csv(ROOT / "data" / "_sample_truth.csv").set_index("review_id")["true_category"].to_dict()
id_map = {}


class FakeResp:
    status_code = 200

    def __init__(self, payload):
        self._p = payload

    def json(self):
        return self._p


def fake_post(url, headers=None, data=None, timeout=None):
    body = json.loads(data)
    user = body["contents"][0]["parts"][0]["text"]
    if user.startswith("Tag these reviews:"):
        items = json.loads(user.split("\n", 1)[1])
        results = []
        for it in items:
            rid = id_map[it["text"], it["id"]] if (it["text"], it["id"]) in id_map else None
            cat = truth.get(rid, "other") if rid else "other"
            if random.random() < 0.08:
                cat = random.choice(list(common.CATEGORIES))
            neg = it["stars"] <= 2
            results.append({"review_id": it["id"],
                            "sentiment": "negative" if neg else "positive" if it["stars"] >= 4 else "neutral",
                            "primary_category": cat, "secondary_category": "",
                            "severity": "none" if cat == "positive_feedback" else "high" if it["stars"] == 1 else "medium",
                            "wont_buy_again": "nunca mais" in it["text"].lower() or "não compro" in it["text"].lower(),
                            "summary_en": f"(mock) customer reports {cat.replace('_', ' ')}"})
        text = json.dumps({"results": results})
    else:  # executive summary
        snap = json.loads(user)
        t = snap["this_month"]
        top = (snap.get("complaints_by_category") or [{}])[0]
        text = json.dumps({
            "headline": f"(mock) {top.get('display_name')} is the costliest complaint this month",
            "summary": f"(mock) Revenue was R$ {t['revenue']} from {t['orders']} orders. "
                       f"Late deliveries were {t['late_pct']}%.",
            "action_1": f"(mock) Ask {top.get('owner_team')} to act.", "action_2": "(mock) b",
            "action_3": "(mock) c"})
    return FakeResp({"candidates": [{"content": {"parts": [{"text": text}]}}],
                     "usageMetadata": {"promptTokenCount": len(user) // 4, "candidatesTokenCount": len(text) // 4}})


requests.post = fake_post

if __name__ == "__main__":
    import tag_reviews
    import exec_summary
    target = sys.argv[1] if len(sys.argv) > 1 else "tags"
    if target == "tags":
        # the real script sends short ids r1..rN; remember which real review each one is
        df = pd.read_csv(common.WORK / "reviews_to_tag.csv", dtype={"review_id": str})
        bs = 40
        for start in range(0, len(df), bs):
            for i, row in enumerate(df.iloc[start:start + bs].itertuples(), 1):
                id_map[str(row.comment_text), f"r{i}"] = row.review_id
        sys.argv = ["tag_reviews.py", "--batch-size", str(bs)]
        tag_reviews.main()
    else:
        sys.argv = ["exec_summary.py"]
        exec_summary.main()
