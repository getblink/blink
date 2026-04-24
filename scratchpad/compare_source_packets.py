#!/usr/bin/env python3

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path
from typing import Any


ROOT_DIR = Path(__file__).resolve().parent.parent
DEFAULT_GOLD_PATH = ROOT_DIR / "scratchpad" / "gold_source_packets.json"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Compare model-generated source packets against a human-authored gold corpus.",
    )
    parser.add_argument(
        "--pred-dir",
        required=True,
        help="Directory containing per-fixture source_packet.json files.",
    )
    parser.add_argument(
        "--gold",
        default=str(DEFAULT_GOLD_PATH),
        help="Path to the gold packet corpus JSON.",
    )
    parser.add_argument(
        "--out-json",
        default=None,
        help="Optional path for a JSON report.",
    )
    parser.add_argument(
        "--out-md",
        default=None,
        help="Optional path for a Markdown summary.",
    )
    return parser.parse_args()


def resolve_path(path_str: str) -> Path:
    path = Path(path_str).expanduser()
    if path.is_absolute():
        return path
    return (ROOT_DIR / path).resolve()


def load_json(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def normalize_text(text: str) -> str:
    tokens = re.findall(r"[a-z0-9]+", text.lower())
    return " ".join(tokens)


def value_matches(a: str, b: str) -> bool:
    a_norm = normalize_text(a)
    b_norm = normalize_text(b)
    if not a_norm or not b_norm:
        return False
    return a_norm in b_norm or b_norm in a_norm


def find_text_line_value(packet_text: str, label: str) -> str | None:
    pattern = re.compile(rf"^{re.escape(label)}:\s*(.+)$", re.MULTILINE)
    match = pattern.search(packet_text)
    if not match:
        return None
    return match.group(1).strip()


def compare_fixture(gold_packet: dict[str, Any], pred_packet: Any, packet_format: str) -> dict[str, Any]:
    if packet_format == "json":
        pred_blob = normalize_text(json.dumps(pred_packet, ensure_ascii=True))
        pred_fields = pred_packet.get("candidate_fields") or []
        pred_source_kind = pred_packet.get("source_kind")
        pred_can_answer = pred_packet.get("can_answer_without_source_image")
        pred_packet_chars = len(json.dumps(pred_packet, ensure_ascii=True))
    else:
        pred_text = str(pred_packet)
        pred_blob = normalize_text(pred_text)
        pred_fields = []
        pred_source_kind = find_text_line_value(pred_text, "SOURCE_KIND")
        completeness_value = find_text_line_value(pred_text, "COMPLETENESS")
        if completeness_value == "sufficient":
            pred_can_answer = True
        elif completeness_value == "needs_source_image":
            pred_can_answer = False
        else:
            pred_can_answer = None
        pred_packet_chars = len(pred_text)

    salient_matches = []
    salient_misses = []
    for text in gold_packet.get("salient_text") or []:
        if normalize_text(text) in pred_blob:
            salient_matches.append(text)
        else:
            salient_misses.append(text)

    strict_field_matches = []
    loose_field_matches = []
    field_misses = []
    for gold_field in gold_packet.get("candidate_fields") or []:
        gold_name = gold_field.get("field") or ""
        gold_value = gold_field.get("value") or ""
        strict_match = False
        if packet_format == "json":
            for pred_field in pred_fields:
                if (pred_field.get("field") or "") != gold_name:
                    continue
                if value_matches(gold_value, pred_field.get("value") or ""):
                    strict_match = True
                    break
        loose_match = normalize_text(gold_value) in pred_blob if gold_value else False
        if strict_match:
            strict_field_matches.append(gold_field)
        elif loose_match:
            loose_field_matches.append(gold_field)
        else:
            field_misses.append(gold_field)

    gold_can_answer = gold_packet.get("can_answer_without_source_image")

    return {
        "packet_format": packet_format,
        "salient_text_total": len(gold_packet.get("salient_text") or []),
        "salient_text_matches": len(salient_matches),
        "salient_text_misses": salient_misses,
        "candidate_fields_total": len(gold_packet.get("candidate_fields") or []),
        "candidate_fields_strict_matches": (
            len(strict_field_matches) if packet_format == "json" else None
        ),
        "candidate_fields_loose_only_matches": len(loose_field_matches),
        "candidate_fields_misses": field_misses,
        "source_kind_match": (gold_packet.get("source_kind") == pred_source_kind),
        "can_answer_match": (
            pred_can_answer is not None and gold_can_answer == pred_can_answer
        ),
        "gold_can_answer_without_source_image": gold_can_answer,
        "pred_can_answer_without_source_image": pred_can_answer,
        "pred_packet_chars": pred_packet_chars,
    }


def build_summary(results: dict[str, dict[str, Any]]) -> dict[str, Any]:
    fixture_count = len(results)
    salient_total = sum(item["salient_text_total"] for item in results.values())
    salient_matches = sum(item["salient_text_matches"] for item in results.values())
    field_total = sum(item["candidate_fields_total"] for item in results.values())
    strict_match_values = [
        item["candidate_fields_strict_matches"]
        for item in results.values()
        if item["candidate_fields_strict_matches"] is not None
    ]
    strict_matches = sum(strict_match_values)
    loose_matches = sum(item["candidate_fields_loose_only_matches"] for item in results.values())
    source_kind_matches = sum(1 for item in results.values() if item["source_kind_match"])
    can_answer_matches = sum(1 for item in results.values() if item["can_answer_match"])
    packet_formats = sorted({item["packet_format"] for item in results.values()})

    return {
        "packet_formats": packet_formats,
        "fixture_count": fixture_count,
        "salient_text_recall": round(salient_matches / salient_total, 3) if salient_total else None,
        "candidate_field_strict_recall": (
            round(strict_matches / field_total, 3) if field_total and strict_match_values else None
        ),
        "candidate_field_loose_recall": round((strict_matches + loose_matches) / field_total, 3)
        if field_total
        else None,
        "source_kind_accuracy": round(source_kind_matches / fixture_count, 3) if fixture_count else None,
        "can_answer_accuracy": round(can_answer_matches / fixture_count, 3) if fixture_count else None,
        "salient_text_total": salient_total,
        "salient_text_matches": salient_matches,
        "candidate_field_total": field_total,
        "candidate_field_strict_matches": strict_matches if strict_match_values else None,
        "candidate_field_loose_only_matches": loose_matches,
        "source_kind_matches": source_kind_matches,
        "can_answer_matches": can_answer_matches,
    }


def write_json(path: Path, payload: Any) -> None:
    path.write_text(json.dumps(payload, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")


def write_markdown(path: Path, summary: dict[str, Any], results: dict[str, dict[str, Any]]) -> None:
    strict_summary = (
        f"`{summary['candidate_field_strict_matches']}/{summary['candidate_field_total']}` "
        f"(`{summary['candidate_field_strict_recall']}`)"
        if summary["candidate_field_strict_recall"] is not None
        else "`n/a`"
    )
    lines = [
        "# Gold Source Packet Comparison",
        "",
        f"- Packet format(s): `{', '.join(summary['packet_formats'])}`",
        f"- Fixture count: `{summary['fixture_count']}`",
        f"- Salient-text recall: `{summary['salient_text_matches']}/{summary['salient_text_total']}` (`{summary['salient_text_recall']}`)",
        f"- Candidate-field strict recall: {strict_summary}",
        f"- Candidate-field loose recall: `{(summary['candidate_field_strict_matches'] or 0) + summary['candidate_field_loose_only_matches']}/{summary['candidate_field_total']}` (`{summary['candidate_field_loose_recall']}`)",
        f"- Source-kind accuracy: `{summary['source_kind_matches']}/{summary['fixture_count']}` (`{summary['source_kind_accuracy']}`)",
        f"- `can_answer_without_source_image` accuracy: `{summary['can_answer_matches']}/{summary['fixture_count']}` (`{summary['can_answer_accuracy']}`)",
        "",
        "## Per Fixture",
        "",
        "| Fixture | Salient recall | Field strict | Field loose-only | Kind | Can-answer |",
        "| --- | ---: | ---: | ---: | --- | --- |",
    ]
    for fixture_id, item in results.items():
        strict_label = (
            f"{item['candidate_fields_strict_matches']}/{item['candidate_fields_total']}"
            if item["candidate_fields_strict_matches"] is not None
            else "n/a"
        )
        lines.append(
            f"| `{fixture_id}` | "
            f"`{item['salient_text_matches']}/{item['salient_text_total']}` | "
            f"`{strict_label}` | "
            f"`{item['candidate_fields_loose_only_matches']}` | "
            f"`{'yes' if item['source_kind_match'] else 'no'}` | "
            f"`{'yes' if item['can_answer_match'] else 'no'}` |"
        )

    lines.extend(["", "## Misses", ""])
    for fixture_id, item in results.items():
        if not item["salient_text_misses"] and not item["candidate_fields_misses"]:
            continue
        lines.append(f"### `{fixture_id}`")
        if item["salient_text_misses"]:
            lines.append("")
            lines.append("Missed salient text:")
            for text in item["salient_text_misses"]:
                lines.append(f"- `{text}`")
        if item["candidate_fields_misses"]:
            lines.append("")
            lines.append("Missed candidate fields:")
            for field in item["candidate_fields_misses"]:
                lines.append(f"- `{field.get('field')}: {field.get('value')}`")
        lines.append("")

    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main() -> int:
    args = parse_args()
    gold_path = resolve_path(args.gold)
    pred_dir = resolve_path(args.pred_dir)

    gold_packets = load_json(gold_path)
    results: dict[str, dict[str, Any]] = {}

    for fixture_id in sorted(gold_packets.keys()):
        pred_json_path = pred_dir / fixture_id / "source_packet.json"
        pred_text_path = pred_dir / fixture_id / "source_packet.txt"
        if pred_json_path.exists():
            pred_packet = load_json(pred_json_path)
            packet_format = "json"
        elif pred_text_path.exists():
            pred_packet = pred_text_path.read_text(encoding="utf-8")
            packet_format = "text"
        else:
            raise FileNotFoundError(
                f"missing predicted packet: {pred_json_path} or {pred_text_path}"
            )
        results[fixture_id] = compare_fixture(gold_packets[fixture_id], pred_packet, packet_format)

    summary = build_summary(results)
    payload = {
        "gold_path": str(gold_path),
        "pred_dir": str(pred_dir),
        "summary": summary,
        "results": results,
    }

    out_json = resolve_path(args.out_json) if args.out_json else pred_dir / "gold_packet_compare.json"
    out_md = resolve_path(args.out_md) if args.out_md else pred_dir / "gold_packet_compare.md"
    write_json(out_json, payload)
    write_markdown(out_md, summary, results)

    print(f"[gold-packets] wrote {out_json}")
    print(f"[gold-packets] wrote {out_md}")
    if summary["candidate_field_strict_matches"] is not None:
        print(
            "[gold-packets] strict field recall:",
            f"{summary['candidate_field_strict_matches']}/{summary['candidate_field_total']}",
        )
    else:
        print(
            "[gold-packets] loose field recall:",
            f"{(summary['candidate_field_strict_matches'] or 0) + summary['candidate_field_loose_only_matches']}/{summary['candidate_field_total']}",
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
