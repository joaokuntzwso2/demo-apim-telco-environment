# Live Gateway-to-Moesif Analytics

## Architecture

The WSO2 API Manager 4.7 Classic Gateway remains the single API enforcement and analytics source. Its native asynchronous Moesif analytics reporter sends successful and faulty events directly to the configured Moesif Collector API. A WSO2 `AnalyticsCustomDataProvider` enriches that native event with telco commercial dimensions; it does not proxy, orchestrate or alter the request.

The existing path remains unchanged:

Consumer → APIM/Gateway → WSO2 Integrator: MI → BSS/OSS backends → Kafka/local observability.

Moesif is an out-of-band branch from APIM:

APIM/Gateway → native APIM analytics queue/reporter → Moesif Collector API.

## Captured data

Native APIM fields provide API, version, operation, application, response status, target response status, request/mediation/backend latency, correlation ID, Gateway type and Gateway region. The custom provider adds partner, API Product, country, named Gateway, subscription identifier/policy, commercial plan, billable units and transaction outcome.

Outcome rules:

- `SUCCESS`: completed invocation with no Gateway/backend failure signal.
- `FAILED`: backend/server/connectivity failure or the controlled demo billing-failure marker.
- `REJECTED`: authentication, authorization, policy/schema or throttling rejection.

## Privacy

`send_headers` is disabled. Payloads, bearer tokens, cookies and API keys are not sent. Only the standard APIM event and explicitly selected metadata are exported. APIM masking is enabled for IP, username, user ID, user agent and application owner.

## Environment variables

Required to start:

- `TELCO_ENABLE_MOESIF_ANALYTICS=true`
- `MOESIF_APPLICATION_ID=<Moesif Collector Application ID>`

Optional runtime values:

- `MOESIF_BASE_URL=https://api.moesif.net`
- `TELCO_GATEWAY_NAME=regional-telco-gateway`
- `TELCO_GATEWAY_REGION=south-america-east`
- `TELCO_GATEWAY_COUNTRY=BR`

Required only for automated proof through the Moesif Management API:

- `MOESIF_MANAGEMENT_TOKEN=<Management API key>`
- `MOESIF_ORG_ID=<workspace/org ID, or ~ when applicable>`

The verifier automatically reads the Regional Portal consumer credentials from the bootstrap state and obtains a client-credentials access token. Set `OBS_ACCESS_TOKEN` or `OBS_AUTHORIZATION` only to override that behavior.

## Start

```bash
export TELCO_ENABLE_MOESIF_ANALYTICS=true
export MOESIF_APPLICATION_ID='replace-with-collector-application-id'
export MOESIF_BASE_URL='https://api.moesif.net'

./scripts/telco-demo-control.sh restart
```

## Verify

```bash
export TELCO_ENABLE_MOESIF_ANALYTICS=true
export MOESIF_APPLICATION_ID='replace-with-collector-application-id'
export MOESIF_MANAGEMENT_TOKEN='replace-with-management-api-key'
export MOESIF_ORG_ID='~'  # or the explicit workspace/org ID

./scripts/verify-live-moesif-analytics.sh
```

The verifier fails if the APIM provider/configuration is absent, the Gateway is unhealthy, APIs/API Products/documents/plans/deployments or Service Catalog entries are incomplete, MI resilience/observability behavior fails, or the three unique events are not queryable in Moesif.
