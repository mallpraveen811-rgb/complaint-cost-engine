"""
STEP: turn free-text customer reviews (Portuguese) into structured data.

Input : data/work/reviews_to_tag.csv   (exported by sql/09_export_reviews_for_ai.sql)
Output: data/work/review_insights.csv  (loaded by sql/10_import_ai_results.sql)

Two modes:
  --mode llm       (default) Gemini reads each review and returns JSON tags
  --mode baseline  simple keyword rules, no API needed. Used to (a) test the pipeline
                   offline and (b) PROVE the LLM adds value: compare both in validate_tags.py

Examples:
  python genai/tag_reviews.py --limit 200                # quick, cheap test run
  python genai/tag_reviews.py                            # everything in the input file
  python genai/tag_reviews.py --mode baseline --output data/work/review_insights_baseline.csv

The script is RESUMABLE: if it stops (quota, Wi-Fi), run it again and it skips
reviews already in the output file.
"""
import argparse
import csv
import json
import re
import sys
import time
import unicodedata

import pandas as pd

from common import CATEGORIES, SENTIMENTS, SEVERITIES, WORK, GeminiClient

OUT_COLUMNS = ["review_id", "sentiment", "primary_category", "secondary_category", "severity",
               "wont_buy_again", "summary_en", "method", "model"]

# ----------------------------------------------------------------------------- prompt
SYSTEM_PROMPT = f"""You are a customer-experience analyst for a Brazilian e-commerce marketplace.
You receive customer reviews written in Portuguese, each with its 1-5 star score.
For EVERY review return one result with:
- review_id: copy the id exactly as given
- sentiment: positive | neutral | negative
- primary_category: the MAIN issue, exactly one of the allowed codes below
- secondary_category: a second issue if clearly present, else ""
- severity: none (no problem) | low (minor annoyance) | medium (real problem, resolved or tolerable)
            | high (product unusable, never arrived, money lost, or customer is angry)
- wont_buy_again: true ONLY if the customer explicitly says they will not buy again / will not
                  recommend the store, otherwise false
- summary_en: one short English sentence (max 15 words) describing what happened

Allowed category codes:
{chr(10).join(f'- {k}: {v}' for k, v in CATEGORIES.items())}

Rules:
- Base the decision on the text; use the star score only to break ties.
- A positive review with a small complaint (e.g. "good product but arrived late") -> category is the
  complaint (late_delivery), sentiment neutral or positive, severity low.
- Never invent details that are not in the text."""

RESPONSE_SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "results": {
            "type": "ARRAY",
            "items": {
                "type": "OBJECT",
                "properties": {
                    "review_id": {"type": "STRING"},
                    "sentiment": {"type": "STRING", "enum": SENTIMENTS},
                    "primary_category": {"type": "STRING", "enum": list(CATEGORIES)},
                    "secondary_category": {"type": "STRING", "enum": list(CATEGORIES) + [""]},
                    "severity": {"type": "STRING", "enum": SEVERITIES},
                    "wont_buy_again": {"type": "BOOLEAN"},
                    "summary_en": {"type": "STRING"},
                },
                "required": ["review_id", "sentiment", "primary_category", "severity",
                             "wont_buy_again", "summary_en"],
            },
        }
    },
    "required": ["results"],
}


def build_user_prompt(batch):
    # short ids (r1, r2 ...) save tokens and stop the model from mangling 32-char hashes
    items = [{"id": f"r{i}", "stars": int(row.review_score),
              "title": "" if pd.isna(row.comment_title) else str(row.comment_title),
              "text": str(row.comment_text)} for i, row in enumerate(batch.itertuples(), 1)]
    return "Tag these reviews:\n" + json.dumps(items, ensure_ascii=False)


def clean_result(res):
    """Never trust model output blindly: force every field into the allowed values."""
    cat = res.get("primary_category")
    sec = res.get("secondary_category") or ""
    return {
        "sentiment": res.get("sentiment") if res.get("sentiment") in SENTIMENTS else "neutral",
        "primary_category": cat if cat in CATEGORIES else "other",
        "secondary_category": sec if sec in CATEGORIES and sec != cat else "",
        "severity": res.get("severity") if res.get("severity") in SEVERITIES else "medium",
        "wont_buy_again": bool(res.get("wont_buy_again", False)),
        "summary_en": str(res.get("summary_en", ""))[:200],
    }


def tag_batch_llm(client, batch):
    data, usage = client.generate_json(SYSTEM_PROMPT, build_user_prompt(batch), RESPONSE_SCHEMA)
    by_short_id = {r.get("review_id"): r for r in data.get("results", [])}
    out = []
    for i, row in enumerate(batch.itertuples(), 1):
        res = by_short_id.get(f"r{i}")
        if res is None:
            continue                       # missing -> picked up again on the next run
        out.append({"review_id": row.review_id, **clean_result(res), "method": "llm", "model": client.model})
    return out, usage


# ----------------------------------------------------------------------------- baseline
def _norm(text):
    text = unicodedata.normalize("NFKD", str(text).lower())
    return "".join(c for c in text if not unicodedata.combining(c))


KEYWORDS = [  # checked in this order; first match wins (that is exactly why rules are weak)
    ("not_delivered", r"nao recebi|nunca chegou|nao chegou|nao foi entregue|ainda nao recebi"),
    ("refund_return_issue", r"reembolso|estorno|devolu|cancel"),
    ("damaged_item", r"quebrad|danificad|defeito|amassad|rachad|nao funciona"),
    ("wrong_item", r"errad|diferente do que|outro modelo|nao e o que pedi"),
    ("missing_parts", r"faltou|faltando|incomplet|so recebi um|veio so"),
    ("late_delivery", r"atras|demor|prazo"),
    ("not_as_described", r"descri|anuncio|foto"),
    ("seller_communication", r"nao respond|sem resposta|atendimento|contato"),
    ("poor_quality", r"qualidade|fraco|fragil|ruim"),
    ("price_value", r"caro|frete"),
    ("positive_feedback", r"otim|excelente|recomendo|perfeito|adorei|bom|gostei|parabens"),
]
NEVER_AGAIN = r"nunca mais compr|nao compro mais|nao recomendo"


def tag_batch_baseline(batch):
    out = []
    for row in batch.itertuples():
        t = _norm(f"{'' if pd.isna(row.comment_title) else row.comment_title} {row.comment_text}")
        cat = next((c for c, pat in KEYWORDS if re.search(pat, t)), "other")
        if cat == "positive_feedback" and int(row.review_score) <= 2:
            cat = "other"
        score = int(row.review_score)
        out.append({"review_id": row.review_id,
                    "sentiment": "positive" if score >= 4 else "neutral" if score == 3 else "negative",
                    "primary_category": cat, "secondary_category": "",
                    "severity": "none" if cat == "positive_feedback" else "high" if score == 1 else
                                "medium" if score == 2 else "low",
                    "wont_buy_again": bool(re.search(NEVER_AGAIN, t)),
                    "summary_en": "", "method": "keyword_baseline", "model": "rules-v1"})
    return out


# ----------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--input", default=str(WORK / "reviews_to_tag.csv"))
    ap.add_argument("--output", default=str(WORK / "review_insights.csv"))
    ap.add_argument("--mode", choices=["llm", "baseline"], default="llm")
    ap.add_argument("--batch-size", type=int, default=40, help="reviews per API call (fewer calls = fits free tier)")
    ap.add_argument("--limit", type=int, default=None, help="only tag the first N reviews (for testing)")
    args = ap.parse_args()

    df = pd.read_csv(args.input, dtype={"review_id": str})
    if args.limit:
        df = df.head(args.limit)

    done = set()
    try:
        done = set(pd.read_csv(args.output, usecols=["review_id"], dtype=str)["review_id"])
    except (FileNotFoundError, ValueError, pd.errors.EmptyDataError):
        with open(args.output, "w", newline="", encoding="utf-8") as f:
            csv.DictWriter(f, OUT_COLUMNS).writeheader()
    todo = df[~df["review_id"].isin(done)]
    print(f"{len(df)} reviews in input, {len(done)} already tagged, {len(todo)} to do (mode={args.mode})")
    if todo.empty:
        return

    client = GeminiClient() if args.mode == "llm" else None
    tokens_in = tokens_out = skipped = 0
    t0 = time.time()
    with open(args.output, "a", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, OUT_COLUMNS)
        for start in range(0, len(todo), args.batch_size):
            batch = todo.iloc[start:start + args.batch_size]
            if client:
                rows, usage = tag_batch_llm(client, batch)
                tokens_in += usage.get("promptTokenCount", 0)
                tokens_out += usage.get("candidatesTokenCount", 0)
            else:
                rows = tag_batch_baseline(batch)
            skipped += len(batch) - len(rows)
            for r in rows:
                r["wont_buy_again"] = "true" if r["wont_buy_again"] else "false"
            writer.writerows(rows)
            f.flush()                                   # progress is saved after every batch
            n = min(start + args.batch_size, len(todo))
            if not client and n < len(todo) and (start // args.batch_size) % 25:
                continue
            print(f"  {n}/{len(todo)} tagged"
                  + (f"  | tokens in {tokens_in:,} out {tokens_out:,}" if client else ""), flush=True)
    print(f"Done in {time.time() - t0:.0f}s -> {args.output}")
    if skipped:
        print(f"{skipped} reviews were skipped by the model; run the script again to fill the gaps.")


if __name__ == "__main__":
    sys.exit(main())
