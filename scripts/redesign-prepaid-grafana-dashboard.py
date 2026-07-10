#!/usr/bin/env python3
from __future__ import annotations

import json
import shutil
from datetime import datetime
from pathlib import Path

ROOT = Path.cwd()
DASHBOARD = ROOT / "observability/grafana/dashboards/prepaid-wallet-reconciliation.json"
BACKUP = ROOT / ".prepaid-reconciliation-backups" / f"friendly-dashboard-{datetime.now():%Y%m%d-%H%M%S}"
DS = {"type": "prometheus", "uid": "prometheus"}
PARTNER = '$partner'
SEL = f'partner="{PARTNER}"'

if not (ROOT / "docker-compose.yml").exists():
    raise SystemExit("Run this script from the repository root.")
if not DASHBOARD.parent.exists():
    raise SystemExit(f"Missing {DASHBOARD.parent}")

BACKUP.mkdir(parents=True, exist_ok=True)
had_dashboard = DASHBOARD.exists()

if had_dashboard:
    shutil.copy2(DASHBOARD, BACKUP / DASHBOARD.name)
else:
    (BACKUP / "created-files.txt").write_text(str(DASHBOARD.relative_to(ROOT)) + "\n")


def steps(*items):
    return {
        "mode": "absolute",
        "steps": [{"color": color, "value": value} for color, value in items],
    }


def target(expr, ref="A", legend=None, instant=True):
    item = {
        "datasource": DS,
        "editorMode": "code",
        "expr": expr,
        "instant": instant,
        "range": not instant,
        "refId": ref,
    }
    if legend:
        item["legendFormat"] = legend
    return item


def text(pid, title, content, x, y, w, h):
    return {
        "id": pid,
        "type": "text",
        "title": title,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "options": {"mode": "markdown", "content": content},
    }


def row(pid, title, y):
    return {
        "id": pid,
        "type": "row",
        "title": title,
        "collapsed": False,
        "gridPos": {"x": 0, "y": y, "w": 24, "h": 1},
        "panels": [],
    }


def stat(
    pid,
    title,
    description,
    expr,
    x,
    y,
    w,
    h,
    *,
    unit="short",
    decimals=0,
    threshold=None,
    mappings=None,
    color_mode="value",
):
    return {
        "id": pid,
        "type": "stat",
        "title": title,
        "description": description,
        "datasource": DS,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "targets": [target(expr)],
        "fieldConfig": {
            "defaults": {
                "unit": unit,
                "decimals": decimals,
                "mappings": mappings or [],
                "color": {"mode": "thresholds"},
                "thresholds": threshold or steps(("green", None)),
            },
            "overrides": [],
        },
        "options": {
            "colorMode": color_mode,
            "graphMode": "none",
            "justifyMode": "auto",
            "orientation": "auto",
            "textMode": "auto",
            "wideLayout": True,
            "reduceOptions": {
                "calcs": ["lastNotNull"],
                "fields": "",
                "values": False,
            },
        },
    }


def bar(
    pid,
    title,
    description,
    queries,
    x,
    y,
    w,
    h,
    *,
    unit="short",
    decimals=0,
):
    return {
        "id": pid,
        "type": "bargauge",
        "title": title,
        "description": description,
        "datasource": DS,
        "gridPos": {"x": x, "y": y, "w": w, "h": h},
        "targets": [
            target(expr, chr(65 + index), legend)
            for index, (expr, legend) in enumerate(queries)
        ],
        "fieldConfig": {
            "defaults": {
                "unit": unit,
                "decimals": decimals,
                "mappings": [],
                "color": {"mode": "continuous-GrYlRd"},
                "thresholds": steps(("green", None)),
            },
            "overrides": [],
        },
        "options": {
            "displayMode": "gradient",
            "orientation": "horizontal",
            "showUnfilled": True,
            "reduceOptions": {
                "calcs": ["lastNotNull"],
                "fields": "",
                "values": False,
            },
        },
    }


status_map = [
    {
        "type": "value",
        "options": {
            "0": {"text": "ACTION REQUIRED", "color": "red", "index": 0},
            "1": {"text": "RECONCILED", "color": "green", "index": 1},
        },
    }
]

panels = [
    text(
        1,
        "How to read this dashboard",
        """
### Prepaid commercial story for **${partner}**

Follow the first row from left to right:

**credit added → credit consumed → credit remaining → protected request rejected → settlement reconciled**

For this demo: **R$0.77 funded − R$0.65 consumed = R$0.12 available**.

The single credit denial is expected. It proves that the request was blocked before backend execution when the balance reached zero.

All Prometheus queries use `max(...)`, preventing the primary and DR meter-store replicas from being counted twice.
""".strip(),
        0,
        0,
        24,
        4,
    ),
    row(2, "1. Prepaid wallet — business outcome", 4),
    stat(
        3,
        "Available credit",
        "Current spendable balance.",
        f'max(telco_prepaid_wallet_balance{{{SEL}}})',
        0,
        5,
        5,
        5,
        unit="currencyBRL",
        decimals=2,
        threshold=steps(("red", None), ("orange", 0.01), ("green", 0.10)),
    ),
    stat(
        4,
        "Credit added",
        "Total successful top-ups.",
        f'max(telco_prepaid_wallet_topup_amount_total{{{SEL}}})',
        5,
        5,
        5,
        5,
        unit="currencyBRL",
        decimals=2,
    ),
    stat(
        5,
        "Credit consumed",
        "Total debits from successful API outcomes.",
        f'max(telco_prepaid_wallet_debited_amount_total{{{SEL}}})',
        10,
        5,
        5,
        5,
        unit="currencyBRL",
        decimals=2,
    ),
    stat(
        6,
        "Protected requests rejected",
        "Expected: 1. This proves prepaid enforcement.",
        f'max(telco_prepaid_credit_denials_total{{{SEL}}})',
        15,
        5,
        4,
        5,
        threshold=steps(("green", None), ("blue", 1)),
    ),
    stat(
        7,
        "Settlement status",
        "Ledger and settlement agree when this is RECONCILED.",
        f'max(telco_commercial_reconciliation_reconciled{{{SEL}}})',
        19,
        5,
        5,
        5,
        threshold=steps(("red", None), ("green", 1)),
        mappings=status_map,
        color_mode="background",
    ),
    bar(
        8,
        "Wallet equation",
        "A direct visual explanation of the final balance.",
        [
            (
                f'max(telco_prepaid_wallet_topup_amount_total{{{SEL}}})',
                "Credit added",
            ),
            (
                f'max(telco_prepaid_wallet_debited_amount_total{{{SEL}}})',
                "Credit consumed",
            ),
            (
                f'max(telco_prepaid_wallet_balance{{{SEL}}})',
                "Available credit",
            ),
        ],
        0,
        10,
        8,
        8,
        unit="currencyBRL",
        decimals=2,
    ),
    {
        "id": 9,
        "type": "timeseries",
        "title": "Available credit over time",
        "description": (
            "Wallet decreases with billable calls, reaches zero, "
            "and recovers after top-up."
        ),
        "datasource": DS,
        "gridPos": {"x": 8, "y": 10, "w": 10, "h": 8},
        "targets": [
            target(
                f'max(telco_prepaid_wallet_balance{{{SEL}}})',
                "A",
                "Available credit",
                False,
            )
        ],
        "fieldConfig": {
            "defaults": {
                "unit": "currencyBRL",
                "decimals": 2,
                "mappings": [],
                "color": {"mode": "palette-classic"},
                "thresholds": steps(("red", None), ("green", 0.01)),
                "custom": {
                    "drawStyle": "line",
                    "lineWidth": 3,
                    "fillOpacity": 20,
                    "showPoints": "always",
                    "pointSize": 6,
                    "lineInterpolation": "smooth",
                    "axisPlacement": "auto",
                    "axisColorMode": "text",
                    "scaleDistribution": {"type": "linear"},
                    "hideFrom": {
                        "legend": False,
                        "tooltip": False,
                        "viz": False,
                    },
                    "stacking": {"mode": "none", "group": "A"},
                },
            },
            "overrides": [],
        },
        "options": {
            "legend": {
                "showLegend": True,
                "displayMode": "table",
                "placement": "bottom",
                "calcs": ["lastNotNull", "min", "max"],
            },
            "tooltip": {"mode": "single", "sort": "none"},
        },
    },
    text(
        10,
        "Demo sequence",
        """
1. Add **R$0.57**
2. Number Verification: **−R$0.08**
3. SIM Swap: **−R$0.14**
4. Quality on Demand: **−R$0.35**
5. Balance reaches **R$0.00**
6. Next request is rejected
7. Add **R$0.20**
8. Number Verification: **−R$0.08**
9. Final balance: **R$0.12**
""".strip(),
        18,
        10,
        6,
        8,
    ),
    row(11, "2. Commercial reconciliation — finance-grade evidence", 18),
    stat(
        12,
        "Open discrepancies",
        "Must be zero after replay and correction.",
        f'max(telco_commercial_reconciliation_discrepancies{{{SEL}}})',
        0,
        19,
        4,
        5,
        threshold=steps(("green", None), ("red", 1)),
    ),
    stat(
        13,
        "Rated usage ledger",
        "Amount calculated from authoritative usage events.",
        f'max(telco_commercial_reconciliation_ledger_amount{{{SEL}}})',
        4,
        19,
        5,
        5,
        unit="currencyBRL",
        decimals=2,
    ),
    stat(
        14,
        "Downstream settlement",
        "Amount represented in settlement records.",
        f'max(telco_commercial_reconciliation_settlement_amount{{{SEL}}})',
        9,
        19,
        5,
        5,
        unit="currencyBRL",
        decimals=2,
    ),
    stat(
        15,
        "Amount difference",
        "Must be R$0.00 when clean.",
        (
            f'abs(max(telco_commercial_reconciliation_ledger_amount{{{SEL}}}) '
            f'- max(telco_commercial_reconciliation_settlement_amount{{{SEL}}}))'
        ),
        14,
        19,
        5,
        5,
        unit="currencyBRL",
        decimals=2,
        threshold=steps(("green", None), ("red", 0.001)),
    ),
    stat(
        16,
        "Record-count difference",
        "Must be zero when all records are accounted for.",
        (
            f'abs(max(telco_commercial_reconciliation_ledger_records{{{SEL}}}) '
            f'- max(telco_commercial_reconciliation_settlement_records{{{SEL}}}))'
        ),
        19,
        19,
        5,
        5,
        threshold=steps(("green", None), ("red", 1)),
    ),
    bar(
        17,
        "Reconciliation exceptions by type",
        "Any non-zero value requires investigation or replay.",
        [
            (
                f'max by (type) '
                f'(telco_commercial_reconciliation_discrepancies_by_type{{{SEL}}})',
                "{{type}}",
            )
        ],
        0,
        24,
        8,
        8,
    ),
    bar(
        18,
        "Ledger versus settlement records",
        "Both counts must match.",
        [
            (
                f'max(telco_commercial_reconciliation_ledger_records{{{SEL}}})',
                "Rated usage records",
            ),
            (
                f'max(telco_commercial_reconciliation_settlement_records{{{SEL}}})',
                "Settlement records",
            ),
        ],
        8,
        24,
        8,
        8,
    ),
    text(
        19,
        "What RECONCILED means",
        """
A clean result means:

- no missing settlement record;
- no amount mismatch;
- no orphan settlement record;
- equal monetary totals;
- equal record counts.

The enterprise billing, charging, or ERP platform remains the official financial system of record.
""".strip(),
        16,
        24,
        8,
        8,
    ),
    row(20, "3. API consumption — what produced the debits", 32),
    bar(
        21,
        "Requests by API operation and outcome",
        (
            "The denied prepaid request is tracked separately because "
            "it is blocked before backend execution."
        ),
        [
            (
                f'max by (meter, outcome) '
                f'(telco_commercial_usage_requests_total{{{SEL}}})',
                "{{meter}} / {{outcome}}",
            )
        ],
        0,
        33,
        12,
        9,
    ),
    bar(
        22,
        "Billed amount by API operation",
        (
            "Outcome-aware billed totals, deduplicated across "
            "primary and DR replicas."
        ),
        [
            (
                f'max by (meter, currency) '
                f'(telco_commercial_billed_amount_total{{{SEL}}})',
                "{{meter}}",
            )
        ],
        12,
        33,
        12,
        9,
        unit="currencyBRL",
        decimals=2,
    ),
]

dashboard = {
    "annotations": {"list": []},
    "description": (
        "Customer-facing prepaid wallet and commercial reconciliation story."
    ),
    "editable": True,
    "fiscalYearStartMonth": 0,
    "graphTooltip": 1,
    "id": None,
    "links": [],
    "panels": panels,
    "refresh": "5s",
    "schemaVersion": 39,
    "tags": [
        "telco",
        "commercial",
        "prepaid",
        "reconciliation",
        "wso2",
        "demo",
    ],
    "templating": {
        "list": [
            {
                "name": "partner",
                "label": "Partner",
                "type": "query",
                "datasource": DS,
                "definition": (
                    "label_values(telco_prepaid_wallet_balance, partner)"
                ),
                "query": {
                    "query": (
                        "label_values(telco_prepaid_wallet_balance, partner)"
                    ),
                    "refId": "VariableQuery",
                },
                "current": {
                    "selected": True,
                    "text": "prepaid-fintech-br-001",
                    "value": "prepaid-fintech-br-001",
                },
                "refresh": 1,
                "sort": 1,
                "multi": False,
                "includeAll": False,
                "options": [],
            }
        ]
    },
    "time": {"from": "now-30m", "to": "now"},
    "timezone": "browser",
    "title": "Prepaid Wallet & Commercial Reconciliation",
    "uid": "prepaid-wallet-reconciliation",
    "version": 3,
}

DASHBOARD.write_text(
    json.dumps(dashboard, indent=2) + "\n",
    encoding="utf-8",
)

json.loads(DASHBOARD.read_text(encoding="utf-8"))

rollback = BACKUP / "rollback.sh"
if had_dashboard:
    rollback.write_text(
        f"""#!/usr/bin/env bash
set -Eeuo pipefail
cd {json.dumps(str(ROOT))}
cp {json.dumps(str(BACKUP / DASHBOARD.name))} {json.dumps(str(DASHBOARD))}
if docker ps --format '{{{{.Names}}}}' | grep -Fxq telco-grafana; then
  docker restart telco-grafana >/dev/null
fi
printf '[rollback][PASS] Restored the previous prepaid dashboard.\\n'
"""
    )
else:
    rollback.write_text(
        f"""#!/usr/bin/env bash
set -Eeuo pipefail
cd {json.dumps(str(ROOT))}
rm -f {json.dumps(str(DASHBOARD))}
if docker ps --format '{{{{.Names}}}}' | grep -Fxq telco-grafana; then
  docker restart telco-grafana >/dev/null
fi
printf '[rollback][PASS] Removed the generated prepaid dashboard.\\n'
"""
    )
rollback.chmod(0o755)

print(f"[PASS] Dashboard written: {DASHBOARD}")
print(f"[PASS] Backup directory: {BACKUP}")
print(f"[PASS] Rollback: bash {rollback}")
