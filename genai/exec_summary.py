"""
STEP: let the LLM write the monthly executive summary shown on the Power BI front page.

  python genai/exec_summary.py                    # uses Gemini
  python genai/exec_summary.py --mode template    # offline fallback (no API)

Input : data/work/kpi_snapshot.json   (made by sql/12_export_kpi_snapshot.sql)
Output: data/work/exec_summary.csv    (loaded by sql/13_import_exec_summary.sql)

Hallucination guard: after the model answers, every number in its text is checked
against the numbers in the snapshot. Numbers that do not appear in the input are
reported, so a made-up figure never reaches the dashboard unnoticed.
"""
import argparse
import csv
import json
import re

from common import WORK, GeminiClient

SYSTEM_PROMPT = """You are a senior business analyst writing a short monthly note for the head of
operations of an e-commerce marketplace. You receive this month's KPIs as JSON.
Rules:
- Use ONLY numbers that appear in the JSON. Do not calculate new percentages or totals.
- Money is in Brazilian reais; write it like R$ 12,345.
- Plain business English, no jargon, no markdown.
- headline: max 15 words, the single most important change this month.
- summary: 3-4 sentences: what happened to revenue and orders, what customers complained about
  most and whether that got better or worse, and which team should care.
- action_1..3: concrete actions, each starting with a verb and naming the team that owns it
  (use owner_team from the JSON). Most valuable action first."""

SCHEMA = {
    "type": "OBJECT",
    "properties": {
        "headline": {"type": "STRING"},
        "summary": {"type": "STRING"},
        "action_1": {"type": "STRING"},
        "action_2": {"type": "STRING"},
        "action_3": {"type": "STRING"},
    },
    "required": ["headline", "summary", "action_1", "action_2", "action_3"],
}


def numbers_in(obj):
    """All numbers that appear anywhere in the snapshot JSON (as rounded strings)."""
    found = set()

    def walk(x):
        if isinstance(x, dict):
            [walk(v) for v in x.values()]
        elif isinstance(x, list):
            [walk(v) for v in x]
        elif isinstance(x, (int, float)) and not isinstance(x, bool):
            for d in (0, 1, 2):
                found.add(f"{round(abs(x), d):.{d}f}")
        elif isinstance(x, str):
            for n in re.findall(r"\d+(?:\.\d+)?", x):
                found.add(n)
    walk(obj)
    return found


def ungrounded_numbers(text, allowed):
    bad = []
    for raw in re.findall(r"\d[\d,]*(?:\.\d+)?", text):
        n = raw.replace(",", "")
        if n in allowed or n.rstrip("0").rstrip(".") in allowed or len(n) <= 1:
            continue
        if n.isdigit() and 1990 <= int(n) <= 2100:      # years are fine
            continue
        if any(a.split(".")[0] == n for a in allowed):   # "1234" vs allowed "1234.56"
            continue
        bad.append(raw)
    return bad


def template_summary(s):
    """Offline fallback: fills a fixed template with the numbers (no AI)."""
    t, p = s.get("this_month") or {}, s.get("previous_month") or {}
    cats = s.get("complaints_by_category") or [{}]
    top = cats[0]
    return {
        "headline": f"Revenue changed {t.get('revenue_mom_pct')}% vs last month; top complaint: {top.get('display_name')}",
        "summary": (f"Orders: {t.get('orders')} (previous month {p.get('orders')}). Revenue: R$ {t.get('revenue')}. "
                    f"Late deliveries: {t.get('late_pct')}%. Top complaint: {top.get('display_name')} with "
                    f"{top.get('complaints_this_month')} complaints (previous month {top.get('complaints_prev_month')})."),
        "action_1": f"Ask {top.get('owner_team')} to review {top.get('display_name', '').lower()} cases.",
        "action_2": "Contact the top risk sellers listed on the seller page.",
        "action_3": "Re-check these numbers next month.",
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mode", choices=["llm", "template"], default="llm")
    ap.add_argument("--snapshot", default=str(WORK / "kpi_snapshot.json"))
    ap.add_argument("--output", default=str(WORK / "exec_summary.csv"))
    a = ap.parse_args()

    with open(a.snapshot, encoding="utf-8") as f:
        snap = json.load(f)
    if not snap.get("this_month"):
        raise SystemExit("Snapshot has no KPIs for this month - run sql/12_export_kpi_snapshot.sql first.")

    if a.mode == "llm":
        client = GeminiClient()
        result, _ = client.generate_json(SYSTEM_PROMPT, json.dumps(snap, ensure_ascii=False), SCHEMA)
        model = client.model
    else:
        result, model = template_summary(snap), "template"

    text = " ".join(str(result.get(k, "")) for k in SCHEMA["properties"])
    bad = ungrounded_numbers(text, numbers_in(snap))
    if bad:
        print(f"WARNING - numbers not found in the input data: {bad}. Read the summary before publishing.")
    else:
        print("Grounding check passed: every number in the summary comes from the data.")

    with open(a.output, "w", newline="", encoding="utf-8") as f:
        w = csv.writer(f)
        w.writerow(["period_month", "headline", "summary", "action_1", "action_2", "action_3", "model"])
        w.writerow([snap["period_month"], result["headline"], result["summary"],
                    result["action_1"], result["action_2"], result["action_3"], model])
    print(f"\n{result['headline']}\n\n{result['summary']}\n")
    for k in ("action_1", "action_2", "action_3"):
        print(" -", result[k])
    print(f"\nSaved -> {a.output}")


if __name__ == "__main__":
    main()
