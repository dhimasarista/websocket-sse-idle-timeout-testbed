#!/usr/bin/env python3
"""Export JSONL experiment logs using only the Python standard library."""

import csv
import json
import math
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LOGS = ROOT / "logs"


def read_jsonl(path: Path, source: str) -> list[dict]:
    if not path.exists():
        return []
    rows = []
    with path.open(encoding="utf-8") as handle:
        for line_number, line in enumerate(handle, 1):
            if not line.strip():
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError as error:
                raise ValueError(f"Invalid JSON in {path}:{line_number}: {error}") from error
            row["source"] = source
            rows.append(row)
    return rows


def percentile(values: list[float], quantile: float) -> float:
    ordered = sorted(values)
    if not ordered:
        return math.nan
    position = (len(ordered) - 1) * quantile
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[lower]
    return ordered[lower] + (ordered[upper] - ordered[lower]) * (position - lower)


records = read_jsonl(LOGS / "server.log", "server") + read_jsonl(LOGS / "client.log", "client")
if not records:
    raise SystemExit("No records found in logs/server.log or logs/client.log")

fieldnames = sorted({key for row in records for key in row})
raw_output = ROOT / "hasil_mentah.csv"
with raw_output.open("w", newline="", encoding="utf-8") as handle:
    writer = csv.DictWriter(handle, fieldnames=fieldnames)
    writer.writeheader()
    writer.writerows(records)

groups: dict[tuple, dict] = {}
for row in records:
    if row.get("source") != "client":
        continue
    key = (
        row.get("implementation_type"),
        row.get("idle_timeout_value"),
        row.get("heartbeat_interval"),
    )
    group = groups.setdefault(key, {"latencies": [], "runs": set(), "survived": 0, "failed": 0})
    if row.get("run_id"):
        group["runs"].add(row["run_id"])
    if row.get("event_type") == "probe_ack" and row.get("latency_ms") is not None:
        group["latencies"].append(float(row["latency_ms"]))
    if row.get("event_type") == "scenario_result":
        if row.get("connection_survived_idle") is True:
            group["survived"] += 1
        else:
            group["failed"] += 1

summary_rows = []
for key, group in sorted(groups.items(), key=lambda item: tuple(str(value) for value in item[0])):
    latencies = group["latencies"]
    completed = group["survived"] + group["failed"]
    summary_rows.append(
        {
            "implementation_type": key[0],
            "idle_timeout_seconds": key[1],
            "heartbeat_interval_seconds": key[2],
            "run_count": len(group["runs"]),
            "completed_count": completed,
            "survived_count": group["survived"],
            "survival_rate": round(group["survived"] / completed, 4) if completed else "",
            "latency_count": len(latencies),
            "latency_mean_ms": round(sum(latencies) / len(latencies), 3) if latencies else "",
            "latency_p95_ms": round(percentile(latencies, 0.95), 3) if latencies else "",
            "latency_p99_ms": round(percentile(latencies, 0.99), 3) if latencies else "",
            "latency_max_ms": round(max(latencies), 3) if latencies else "",
        }
    )

summary_output = ROOT / "hasil_ringkas.csv"
with summary_output.open("w", newline="", encoding="utf-8") as handle:
    writer = csv.DictWriter(handle, fieldnames=list(summary_rows[0]) if summary_rows else [])
    if summary_rows:
        writer.writeheader()
        writer.writerows(summary_rows)

print(f"Wrote {raw_output} ({len(records)} rows)")
print(f"Wrote {summary_output} ({len(summary_rows)} scenario groups)")
