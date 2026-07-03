#!/usr/bin/env bash
set -euo pipefail

BROKER_CONTAINER="${BROKER_CONTAINER:-telco-redpanda}"
TOPIC="telco.network.qod.events"

python3 - <<'PY' | docker exec -i "$BROKER_CONTAINER" rpk topic produce "$TOPIC" --brokers localhost:9092
import json
import time

event = {
  "eventId": f"evt-network-sla-{int(time.time())}",
  "eventType": "NETWORK_SLA_DEGRADATION",
  "topic": "telco.network.qod.events",
  "partnerId": "enterprise-private-5g",
  "country": "BR",
  "region": "Sao Paulo",
  "sliceId": "slice-enterprise-sp-001",
  "severity": "CRITICAL",
  "latencyMs": 92,
  "packetLossPct": 2.4,
  "commercial": {
    "billable": True,
    "meter": "sla_alert_delivery",
    "productKey": "moesif_prod_event_native_broker_simulation",
    "billingCatalogReference": "billing.catalog.event-native-broker-simulation.v1",
    "revenueShareModel": "EVENT_STREAM_REVENUE_SHARE",
    "settlementOwner": "Telco Network Monetization Office"
  },
  "story": "A real Kafka-protocol network SLA event was produced and can be metered as an event-native API product."
}

print(json.dumps(event, separators=(",", ":")))
PY
