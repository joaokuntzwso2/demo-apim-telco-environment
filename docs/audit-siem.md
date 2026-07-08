# Audit and SIEM scenario

## Purpose

The scenario exposes `TelcoAuditEventsAPI:1.0.0` through WSO2 API Manager and implements the ingestion flow as a real WSO2 Integrator: MI API. MI validates and normalizes each event, preserves or creates `X-Correlation-ID`, returns `202 Accepted`, and asynchronously sends the event to the existing telemetry service. Fluent Bit tails `events.jsonl`, labels it as `job=telco.structured`, and sends it to Loki. Grafana provisions the dashboard **Telco API Platform - Audit and SIEM**.

## Auditable event model

Every event contains `actor`, `timestamp`, `country`, `resource`, `action`, `result`, `eventType`, `auditId`, and `correlationId`. Supported event types are API publication, policy modification, subscription approval, credential creation, failed authentication, excessive SIM Swap requests, billing correction, and administrator action.

## Security and consent

The managed POST operation requires OAuth 2.0 and the `telco_audit_write` scope. Audit payloads must not contain access tokens, client secrets, full payment data, or unnecessary subscriber attributes. The demo records identifiers and operational metadata only. Production deployments should apply retention, redaction, legal-basis, workforce-access and cross-border transfer policies appropriate to each operating company.

## Error model

Invalid events return `400 application/problem+json`. Unexpected mediation failures return a normalized `500 application/problem+json`. Missing/invalid gateway credentials return `401`, insufficient scopes return `403`, and quota violations return `429`. All responses preserve `X-Correlation-ID`.

## Reliability and SLA behavior

The MI delivery endpoint uses a three-second timeout, two bounded retries before suspension, exponential endpoint suspension, and a failover endpoint. The caller receives `202` after validation so an observability outage does not block the business request. In this single-node demo the backup DNS alias points to the same telemetry service; production must use an independently deployed secondary collector or SIEM ingress.

## Sandbox example

```json
{
  "eventType": "FAILED_AUTHENTICATION",
  "actor": "partner-sandbox-001",
  "country": "BR",
  "resource": "/audit-events/v1/events",
  "action": "AUTHENTICATE_API_REQUEST",
  "result": "DENIED",
  "details": {
    "httpStatus": 401,
    "credentialType": "Bearer",
    "secretMaterialIncluded": false
  }
}
```

## Postman and SDK

Import `artifacts/postman/telco-audit-siem.postman_collection.json`. Set `accessToken` to an APIM OAuth token carrying `telco_audit_write`. Language-neutral SDK instructions and curl examples are in `artifacts/sdk/audit-siem/README.md`. APIM also exposes generated SDK downloads from the Developer Portal after publication.
