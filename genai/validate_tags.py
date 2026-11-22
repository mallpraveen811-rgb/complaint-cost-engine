"""
STEP: measure the LLM's accuracy against YOUR manual labels (and against the keyword baseline).

  python genai/validate_tags.py
  python genai/validate_tags.py --baseline data/work/review_insights_baseline.csv

Reads   data/work/validation_to_label.csv   (filled in by you)
        data/work/review_insights.csv       (LLM tags)
Writes  data/work/validation_report.md      (accuracy, per-category precision/recall, confusion table)
        data/work/validation_labels.csv     (your labels, loadable into SQL with sql/11_import_validation.sql)

Metrics, in plain words:
  accuracy  = share of reviews where the tag equals your label
  precision = when the model says "damaged_item", how often is it right?
  recall    = of all reviews that really are "damaged_item", how many did the model find?
  F1        = one number that balances precision and recall
"""
import argparse

import pandas as pd

from common import CATEGORIES, WORK


def metrics(truth, pred):
    df = pd.DataFrame({"truth": truth.values, "pred": pred.values})
    acc = (df.truth == df.pred).mean()
    rows = []
    for c in CATEGORIES:
        tp = ((df.pred == c) & (df.truth == c)).sum()
        fp = ((df.pred == c) & (df.truth != c)).sum()
        fn = ((df.pred != c) & (df.truth == c)).sum()
        if tp + fp + fn == 0:
            continue
        p = tp / (tp + fp) if tp + fp else 0.0
        r = tp / (tp + fn) if tp + fn else 0.0
        f1 = 2 * p * r / (p + r) if p + r else 0.0
        rows.append({"category": c, "support": int(tp + fn), "precision": round(p, 3),
                     "recall": round(r, 3), "f1": round(f1, 3)})
    per_cat = pd.DataFrame(rows)
    macro_f1 = per_cat["f1"].mean() if len(per_cat) else 0.0
    confusion = pd.crosstab(df.truth, df.pred, rownames=["your label"], colnames=["model tag"])
    return acc, macro_f1, per_cat, confusion


def to_md(df):
    """Markdown table without needing the optional 'tabulate' package."""
    df = df.reset_index() if df.index.name or isinstance(df.index, pd.MultiIndex) else df
    cols = [str(c) for c in df.columns]
    lines = ["| " + " | ".join(cols) + " |", "|" + "---|" * len(cols)]
    lines += ["| " + " | ".join(str(v) for v in row) + " |" for row in df.itertuples(index=False)]
    return "\n".join(lines)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--labels", default=str(WORK / "validation_to_label.csv"))
    ap.add_argument("--tags", default=str(WORK / "review_insights.csv"))
    ap.add_argument("--baseline", default=None, help="optional keyword-baseline tags to compare")
    ap.add_argument("--report", default=str(WORK / "validation_report.md"))
    ap.add_argument("--labeller", default="me")
    a = ap.parse_args()

    labels = pd.read_csv(a.labels, dtype={"review_id": str}, encoding="utf-8-sig")
    labels["manual_category"] = labels["manual_category"].fillna("").str.strip().str.lower()
    labels = labels[labels["manual_category"] != ""]
    bad = labels[~labels["manual_category"].isin(CATEGORIES)]
    if len(bad):
        print(f"WARNING: {len(bad)} labels are not valid category codes and are ignored: "
              f"{sorted(bad['manual_category'].unique())[:10]}")
        labels = labels[labels["manual_category"].isin(CATEGORIES)]
    if labels.empty:
        raise SystemExit("No manual labels found. Fill the manual_category column first.")

    tags = pd.read_csv(a.tags, dtype={"review_id": str})
    m = labels.merge(tags[["review_id", "primary_category", "sentiment"]], on="review_id", how="inner")
    acc, f1, per_cat, conf = metrics(m["manual_category"], m["primary_category"])

    out = [f"# LLM tagging validation\n",
           f"Reviews compared: **{len(m)}**  \n",
           f"**Accuracy: {acc:.1%}**  |  Macro F1: {f1:.3f}\n"]
    if "manual_sentiment" in m and m["manual_sentiment"].notna().any():
        s = m[m["manual_sentiment"].fillna("").str.strip() != ""]
        if len(s):
            out.append(f"Sentiment accuracy: {(s['manual_sentiment'].str.strip().str.lower() == s['sentiment']).mean():.1%}"
                       f" ({len(s)} labelled)\n")
    # simpler question a manager cares about: did it spot complaint vs no complaint?
    is_c = lambda x: x.isin([c for c in CATEGORIES if c not in ("positive_feedback", "other")])
    out.append(f"Complaint vs no-complaint accuracy: {(is_c(m['manual_category']) == is_c(m['primary_category'])).mean():.1%}\n")

    if a.baseline:
        b = pd.read_csv(a.baseline, dtype={"review_id": str})
        mb = labels.merge(b[["review_id", "primary_category"]], on="review_id", how="inner")
        b_acc, b_f1, _, _ = metrics(mb["manual_category"], mb["primary_category"])
        out.append(f"\n## LLM vs keyword rules\n\n| method | accuracy | macro F1 |\n|---|---|---|\n"
                   f"| LLM | {acc:.1%} | {f1:.3f} |\n| Keyword baseline | {b_acc:.1%} | {b_f1:.3f} |\n")
        print(f"Baseline accuracy: {b_acc:.1%}  (macro F1 {b_f1:.3f})")

    out.append("\n## Per category\n\n" + to_md(per_cat) + "\n")
    out.append("\n## Confusion table (rows = your label, columns = model tag)\n\n" + to_md(conf) + "\n")
    wrong = m[m["manual_category"] != m["primary_category"]].head(15)
    if len(wrong):
        out.append("\n## Examples the model got wrong (look for patterns -> improve the prompt)\n\n"
                   + to_md(wrong[["review_id", "manual_category", "primary_category"]]) + "\n")
    with open(a.report, "w", encoding="utf-8") as f:
        f.write("\n".join(out))

    labels.assign(labelled_by=a.labeller)[["review_id", "manual_category", "manual_sentiment", "labelled_by"]] \
        .to_csv(WORK / "validation_labels.csv", index=False)
    print(f"LLM accuracy: {acc:.1%}  (macro F1 {f1:.3f}) on {len(m)} reviews -> {a.report}")


if __name__ == "__main__":
    main()
