#!/usr/bin/env python3
"""
Generate a simple HTML compliance report from:
  1. <image>-compliance-report.csv
  2. <image>-compliance-summary.csv
"""

import csv
import sys
from pathlib import Path
from html import escape


def load_csv(path):
    with path.open("r", encoding="utf-8", newline="") as f:
        return list(csv.DictReader(f))


def status_color(status):
    return {
        "PASS": "#d4edda",
        "WARN": "#f8d7da",
        "INFO": "#d1ecf1",
        "NOTE": "#e2e3e5",
    }.get(status, "#ffffff")


def main():
    if len(sys.argv) != 4:
        print(
            "Usage: generate_docker_cis_html.py "
            "<compliance.csv> <summary.csv> <output.html>"
        )
        sys.exit(1)

    csv_path = Path(sys.argv[1])
    summary_path = Path(sys.argv[2])
    output_path = Path(sys.argv[3])

    findings = load_csv(csv_path)
    summary = load_csv(summary_path)

    html = [
        "<!DOCTYPE html>",
        "<html>",
        "<head>",
        "<meta charset='utf-8'>",
        "<title>Docker CIS Compliance Report</title>",
        "<style>",
        "body { font-family: Arial, sans-serif; margin: 20px; }",
        "table { border-collapse: collapse; width: 100%; margin-bottom: 30px; }",
        "th, td { border: 1px solid #ccc; padding: 8px; vertical-align: top; }",
        "th { background: #2c3e50; color: white; }",
        "h1, h2 { color: #2c3e50; }",
        "</style>",
        "</head>",
        "<body>",
        "<h1>Docker CIS Compliance Report</h1>",
        "<h2>Summary</h2>",
        "<table>",
        "<tr><th>Metric</th><th>Count</th></tr>",
    ]

    for row in summary:
        html.append(
            f"<tr><td>{escape(row['Metric'])}</td>"
            f"<td>{escape(row['Count'])}</td></tr>"
        )

    html.extend([
        "</table>",
        "<h2>Detailed Findings</h2>",
        "<table>",
        "<tr>",
        "<th>REF</th>",
        "<th>Standard</th>",
        "<th>Status</th>",
        "<th>Description/Rationale</th>",
        "<th>Audit</th>",
        "<th>Remediation</th>",
        "</tr>",
    ])

    for row in findings:
        status = row.get("Status", "")
        color = status_color(status)

        html.append(
            f"<tr style='background:{color}'>"
            f"<td>{escape(row.get('REF', ''))}</td>"
            f"<td>{escape(row.get('Standard', ''))}</td>"
            f"<td>{escape(status)}</td>"
            f"<td>{escape(row.get('Description/Rationale', ''))}</td>"
            f"<td>{escape(row.get('Audit', ''))}</td>"
            f"<td>{escape(row.get('Remediation', ''))}</td>"
            f"</tr>"
        )

    html.extend([
        "</table>",
        "</body>",
        "</html>",
    ])

    output_path.write_text("\n".join(html), encoding="utf-8")
    print(output_path)


if __name__ == "__main__":
    main()