"""
STEP: create a blind labelling sheet to measure how accurate the LLM is.

Picks N random reviews that the LLM has tagged and writes them WITHOUT the LLM's
answers (so you are not influenced). You fill in `manual_category` yourself in Excel,
then run validate_tags.py.

  python genai/build_validation_sample.py --n 200
  -> data/work/validation_to_label.csv   (open in Excel, fill the manual_category column)

Allowed values for manual_category are printed below and listed in the README.
Tip: 200 reviews take about 45-60 minutes. Use Google Translate if your Portuguese is rusty.
"""
import argparse

import pandas as pd

from common import CATEGORIES, WORK


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--n", type=int, default=200)
    ap.add_argument("--reviews", default=str(WORK / "reviews_to_tag.csv"))
    ap.add_argument("--tags", default=str(WORK / "review_insights.csv"))
    ap.add_argument("--output", default=str(WORK / "validation_to_label.csv"))
    ap.add_argument("--seed", type=int, default=7)
    a = ap.parse_args()

    reviews = pd.read_csv(a.reviews, dtype={"review_id": str})
    tagged = pd.read_csv(a.tags, dtype={"review_id": str}, usecols=["review_id"])
    pool = reviews[reviews["review_id"].isin(tagged["review_id"])]
    sample = pool.sample(n=min(a.n, len(pool)), random_state=a.seed)
    sheet = sample[["review_id", "review_score", "comment_title", "comment_text"]].copy()
    sheet["manual_category"] = ""
    sheet["manual_sentiment"] = ""
    # utf-8-sig so Excel on Windows shows Portuguese accents correctly
    sheet.to_csv(a.output, index=False, encoding="utf-8-sig")
    print(f"Wrote {len(sheet)} reviews to {a.output}")
    print("Allowed manual_category values:\n  " + "\n  ".join(CATEGORIES))
    print("Allowed manual_sentiment values: positive, neutral, negative")


if __name__ == "__main__":
    main()
