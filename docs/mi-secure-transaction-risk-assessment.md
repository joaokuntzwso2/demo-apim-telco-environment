# Secure Transaction Risk Assessment with WSO2 Integrator: MI

## Architecture

```text
Partner
  |
  v
WSO2 API Manager 4.7 (security, throttling, products, analytics)
  |
  v
WSO2 Integrator: MI 4.6.0
  |---------------------- parallel scatter/gather ----------------------|
  v                       v                       v                      v
Legacy CRM XML       SIM Swap JSON        Device Location JSON    Legacy OSS text
```

The gateway remains lightweight. All protocol conversion, orchestration,
fault isolation, aggregation and risk-decision logic is implemented in MI.

## What is implemented

- Separate WSO2 Integrator: MI 4.6.0 container.
- Four separately addressable downstream services.
- JSON -> XML -> JSON CRM transformation.
- JSON -> pipe-delimited text -> JSON OSS transformation.
- Parallel Scatter Gather with a 7-second aggregation timeout.
- Per-backend 1.5-second timeout.
- One same-request retry through a two-child failover endpoint.
- Endpoint suspension/circuit breaking with exponential suspension:
  5 seconds, progression factor 2, maximum 30 seconds.
- End-to-end `X-Correlation-ID`.
- `ALLOW_DEGRADED` and `FAIL_CLOSED` partial-response policies.
- Normalized errors and evidence envelopes.
- MI Service Catalog publication.
- Automatic managed API import, deployment, publication and subscription
  through the existing APIM bootstrapper.

## Deterministic demo data

The last MSISDN digit controls selected outcomes:

| Last digit | Outcome |
|---|---|
| 9 | CRM account suspended |
| 8 | SIM swap within 3 hours |
| 7 | CRM fraud watch |
| 5 | Device country mismatch |
| 4 | Roaming |
| 3 | Degraded network |

## Chaos headers

- `X-Demo-Fail-Service`: `crm`, `sim-swap`, `device-location`, `oss`, `all`
- `X-Demo-Fail-Mode`: `transport` (default) or `http`
- `X-Demo-Delay-Service`: same service names
- `X-Demo-Delay-Ms`: latency in milliseconds

Use `transport` failure to demonstrate MI endpoint failover, retry and
circuit-breaker state. Use delay above 1500 ms to demonstrate timeout handling.

## Start and test

```bash
./scripts/run-with-mi-risk.sh
./scripts/test-mi-risk.sh
```

## Service Catalog

Open Publisher at `https://localhost:9443/publisher`, then open **Services**.
MI publishes its deployed APIs to the Service Catalog during startup. The main
`SecureTransactionRiskAssessmentAPI` is also imported and published as a
managed APIM API by the repository bootstrapper.

## Useful diagnostics

```bash
docker compose -f docker-compose.yml -f docker-compose.mi.yml ps

docker compose -f docker-compose.yml -f docker-compose.mi.yml \
  logs -f wso2-mi

docker compose -f docker-compose.yml -f docker-compose.mi.yml \
  logs -f subscriber-crm sim-swap-service device-location-service oss-network-service
```

## Configuration

Runtime endpoints, credentials, timeout and circuit-breaker durations are in:

```text
services/wso2-mi/conf/file.properties
docker-compose.mi.yml
```

Environment variables with the same names override `file.properties`.

## Services published by MI

The following deployed REST APIs are registered in APIM's **Services** catalog:

```text
SecureTransactionRiskAssessmentAPI
CrmRiskAdapterAPI
SimSwapRiskAdapterAPI
DeviceLocationRiskAdapterAPI
OssRiskAdapterAPI
```

The four adapter APIs are intentionally separate integration services so the demo can show protocol mediation, downstream fault isolation, and individual service contracts. The partner-facing managed API is the `SecureTransactionRiskAssessmentAPI` façade created by the APIM bootstrapper.

## Why native HTTP/failover endpoints are used here

For straightforward outbound HTTP calls, the current MI tooling offers the HTTP Connector. This demonstration intentionally uses native HTTP child endpoints inside a Failover Endpoint because the scenario specifically needs visible endpoint states, transport-error retry, suspension, and circuit-breaker-style fast failure. Scatter Gather is used for the orchestration fan-out because it is the current replacement for separate Clone and Aggregate mediators.

## Production hardening

- Replace the demo backend keys with Secure Vault or an external enterprise vault.
- Replace all backend HTTP URLs with TLS/mTLS endpoints where required.
- Use certificates whose SAN values match Docker/Kubernetes DNS names, import the issuing CA into the truststore, remove `AllowAll`, and retain strict hostname verification.
- Restrict the four `/internal/risk/...` APIs using network policy or expose them only on an internal listener; only the partner façade should be externally reachable.
- Tune timeouts and endpoint suspension values using load and failure testing against actual CRM/BSS/OSS dependencies.
- Connect MI logs/traces to the selected observability platform and avoid logging sensitive subscriber payloads.
