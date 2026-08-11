import json
from pathlib import Path

import pandas as pd

root = Path(__file__).resolve().parent.parent
logs = root / "logs"
server_log = logs / "server.log"
client_log = logs / "client.log"


def read_jsonl(path: Path, source: str):
    if not path.exists():
        return []
    rows = []
    with path.open(encoding="utf-8") as handle:
        for line in handle:
            if line.strip():
                row = json.loads(line)
                row["source"] = source
                rows.append(row)
    return rows


records = read_jsonl(server_log, "server") + read_jsonl(client_log, "client")
df = pd.DataFrame(records)
out = root / "hasil_mentah.csv"
df.to_csv(out, index=False)

print(f"Wrote {out} ({len(df)} rows)")

if not df.empty and "event_type" in df:
    summary = (
        df[df["event_type"].eq("probe_ack")]
        .groupby(["implementation_type"], dropna=False)["latency_ms"]
        .agg(["count", "mean", "max"])
        .reset_index()
    )
    print(summary.to_string(index=False))
