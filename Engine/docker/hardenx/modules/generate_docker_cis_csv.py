#!/usr/bin/env python3
"""
generate_docker_cis_csv.py

Merge:
  1. data/docker-cis-controls.csv
  2. docker-bench.log

Produce:
  - Enriched compliance CSV
  - Summary CSV
  - JSON report

Usage:
  generate_docker_cis_csv.py \
      <controls.csv> \
      <docker-bench.log> \
      <output.csv> \
      <summary.csv>

Example:
  python3 generate_docker_cis_csv.py \
      data/docker-cis-controls.csv \
      docker-bench.log \
      flask-lab-v1-compliance-report.csv \
      flask-lab-v1-compliance-summary.csv

Outputs:
  - <output.csv>
  - <summary.csv>
  - <output directory>/<base name>.json
"""

import csv
import json
import re
import sys
from pathlib import Path
from collections import Counter
from datetime import datetime


# ============================================================================
# Detect CSV Delimiter
# ============================================================================
def detect_delimiter(path: Path) -> str:
    with path.open("r", encoding="utf-8", newline="") as f:
        first_line = f.readline()
    return "\t" if "\t" in first_line else ","


# ============================================================================
# Load Control Metadata
# ============================================================================
def load_controls(path: Path):
    delimiter = detect_delimiter(path)
    controls = {}

    with path.open("r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f, delimiter=delimiter)

        for row in reader:
            ref = (row.get("REF") or "").strip()

            if not ref:
                continue

            # Skip section headers such as A, B, C, D, E
            if re.fullmatch(r"[A-Z]", ref):
                continue

            controls[ref] = {
                "REF": ref,
                "Standard": (row.get("Standard") or "").strip(),
                "Description/Rationale": (
                    row.get("Description/Rationale") or ""
                ).strip(),
                "Audit": (row.get("Audit") or "").strip(),
                "Remediation": (row.get("Remediation") or "").strip(),
            }

    return controls


# ============================================================================
# Parse Docker Bench Output
# ============================================================================
def parse_bench_log(path: Path):
    statuses = {}

    # Docker Bench section-to-control mapping
    # 1.x -> A
    # 2.x -> B
    # 3.x -> C
    # 4.x -> D
    # 5.x -> E
    section_map = {
        "1": "A",
        "2": "B",
        "3": "C",
        "4": "D",
        "5": "E",
    }

    # Remove ANSI color sequences
    ansi_re = re.compile(r"\x1B\[[0-9;]*[A-Za-z]")

    # Match:
    # [PASS] 2.14 - Ensure ...
    pattern = re.compile(r"^\[(PASS|WARN|INFO|NOTE)\]\s+(\d+)\.(\d+)\s+-")

    with path.open("r", encoding="utf-8", errors="ignore") as f:
        for line in f:
            line = ansi_re.sub("", line).strip()

            match = pattern.match(line)
            if not match:
                continue

            status, major, minor = match.groups()

            if major not in section_map:
                continue

            ref = f"{section_map[major]}{int(minor)}"
            statuses[ref] = status

    return statuses


# ============================================================================
# Write Enriched CSV
# ============================================================================
def write_enriched_csv(controls, statuses, output_path: Path):
    fieldnames = [
        "REF",
        "Standard",
        "Description/Rationale",
        "Audit",
        "Remediation",
        "Status",
    ]

    with output_path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()

        for ref in sorted(statuses.keys()):
            control = controls.get(ref)

            if control:
                row = dict(control)
            else:
                row = {
                    "REF": ref,
                    "Standard": "Control metadata not found",
                    "Description/Rationale": "",
                    "Audit": "",
                    "Remediation": "",
                }

            row["Status"] = statuses[ref]
            writer.writerow(row)


# ============================================================================
# Write Summary CSV
# ============================================================================
def write_summary_csv(statuses, output_path: Path):
    counts = Counter(statuses.values())

    with output_path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["Metric", "Count"])

        for status in ["PASS", "WARN", "INFO", "NOTE"]:
            writer.writerow([status, counts.get(status, 0)])


# ============================================================================
# Write JSON Report
# ============================================================================
def write_json_report(controls, statuses, output_path: Path):
    counts = Counter(statuses.values())
    items = []

    for ref in sorted(statuses.keys()):
        control = controls.get(
            ref,
            {
                "REF": ref,
                "Standard": "Control metadata not found",
                "Description/Rationale": "",
                "Audit": "",
                "Remediation": "",
            },
        )

        items.append(
            {
                "ref": ref,
                "standard": control.get("Standard", ""),
                "description": control.get("Description/Rationale", ""),
                "audit": control.get("Audit", ""),
                "remediation": control.get("Remediation", ""),
                "status": statuses[ref],
            }
        )

    report = {
        "benchmark": "CIS Docker Benchmark",
        "generated_at": datetime.utcnow().isoformat() + "Z",
        "summary": {
            "PASS": counts.get("PASS", 0),
            "WARN": counts.get("WARN", 0),
            "INFO": counts.get("INFO", 0),
            "NOTE": counts.get("NOTE", 0),
            "TOTAL": sum(counts.values()),
        },
        "controls": items,
    }

    with output_path.open("w", encoding="utf-8") as f:
        json.dump(report, f, indent=2)


# ============================================================================
# Main
# ============================================================================
def main():
    if len(sys.argv) != 5:
        print(
            "Usage: generate_docker_cis_csv.py "
            "<controls.csv> <docker-bench.log> "
            "<output.csv> <summary.csv>"
        )
        sys.exit(1)

    controls_file = Path(sys.argv[1])
    bench_log = Path(sys.argv[2])
    output_csv = Path(sys.argv[3])
    summary_csv = Path(sys.argv[4])

    # JSON filename follows the same base name as the output CSV
    # Example:
    #   flask-lab-v1-compliance-report.csv
    #   -> flask-lab-v1-compliance-report.json
    json_output = output_csv.with_suffix(".json")

    # ------------------------------------------------------------------------
    # Validate Inputs
    # ------------------------------------------------------------------------
    if not controls_file.exists():
        print(f"[ERROR] Controls file not found: {controls_file}")
        sys.exit(1)

    if not bench_log.exists():
        print(f"[ERROR] Docker Bench log not found: {bench_log}")
        sys.exit(1)

    # ------------------------------------------------------------------------
    # Process Data
    # ------------------------------------------------------------------------
    controls = load_controls(controls_file)
    statuses = parse_bench_log(bench_log)

    # ------------------------------------------------------------------------
    # Generate Reports
    # ------------------------------------------------------------------------
    write_enriched_csv(controls, statuses, output_csv)
    write_summary_csv(statuses, summary_csv)
    write_json_report(controls, statuses, json_output)

    # Print only the main CSV path (suppressed in quiet mode by the caller)
    print(output_csv)


if __name__ == "__main__":
    main()