"""
Convert compact tags (idx|cat|secondary|severity|wont_buy_again|sentiment) into the
standard data/work/review_insights.csv format that sql/10_import_ai_results.sql loads.

Used for the run where the LLM's answers were saved in compact form
(same instructions and categories as tag_reviews.py's SYSTEM_PROMPT).
  python genai/convert_compact_tags.py --model claude-opus-5-5
"""
import argparse
import glob

import pandas as pd

from common import WORK

CODES = {"LD": "late_delivery", "ND": "not_delivered", "DM": "damaged_item", "WI": "wrong_item",
         "MP": "missing_parts", "PQ": "poor_quality", "NA": "not_as_described", "SC": "seller_communication",
         "RF": "refund_return_issue", "PV": "price_value", "PF": "positive_feedback", "OT": "other"}
SEV = {"n": "none", "l": "low", "m": "medium", "h": "high"}
SENT = {"p": "positive", "u": "neutral", "n": "negative"}

ap = argparse.ArgumentParser()
ap.add_argument("--model", default="claude-opus-5-5")
a = ap.parse_args()

rows = []
for f in sorted(glob.glob(str(WORK / "tags_*.txt"))):
    for line in open(f, encoding="utf-8"):
        if line.strip():
            i, c, s2, sev, w, s = line.strip().split("|")
            rows.append({"idx": int(i), "primary_category": CODES[c],
                         "secondary_category": "" if s2 == "-" else CODES[s2], "severity": SEV[sev],
                         "wont_buy_again": "true" if w == "1" else "false", "sentiment": SENT[s]})
tags = pd.DataFrame(rows)
assert tags.idx.is_unique, "duplicate idx"
idx = pd.read_csv(WORK / "sample_index.csv", dtype={"review_id": str})[["idx", "review_id"]]
out = idx.merge(tags, on="idx", how="inner")
summ = WORK / "summaries_en.csv"
out["summary_en"] = ""
if summ.exists():
    s = pd.read_csv(summ).set_index("idx")["summary_en"]
    out["summary_en"] = out["idx"].map(s).fillna("")
out["method"], out["model"] = "llm", a.model
cols = ["review_id", "sentiment", "primary_category", "secondary_category", "severity",
        "wont_buy_again", "summary_en", "method", "model"]
out = out.drop_duplicates("review_id")
out[cols].to_csv(WORK / "review_insights.csv", index=False)
print(f"{len(out)} tagged reviews -> {WORK / 'review_insights.csv'} (missing: {idx.review_id.nunique() - len(out)})")
print(out.primary_category.value_counts().to_string())
