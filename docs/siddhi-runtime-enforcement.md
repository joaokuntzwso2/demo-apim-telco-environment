# Runtime enforcement of the Siddhi controls

## Purpose

The custom throttling policies are no longer only visible configuration in APIM Admin. Their Siddhi predicates match the real published API contexts and versions, the APIM Traffic Manager evaluates request events, and the Classic Gateway returns a normalized 429 response while publishing an operational alert through WSO2 Integrator: MI to Kafka.

## Runtime controls

| Policy | Key | Demo condition | Retry-After | Public API |
|---|---|---:|---:|---|
| `TelcoSiddhiSimSwapFraudFairUsePolicy` | APIM application + API context + version | 6 requests / 15-second time batch | 15 seconds | `OpenGatewaySimSwapRiskAPI:1.0.0` |
| `TelcoSiddhiQoDAssuranceBurstPolicy` | API context + version | 9 requests / 5-second time batch | 5 seconds | `NetworkSliceAPI:1.0.0` QoD operation |

These values are deliberately small for deterministic demonstration. They are not production recommendations.

## Enforcement and alert path

1. A subscribed application invokes the SIM Swap or QoD operation through APIM.
2. The Gateway emits request metadata to the Traffic Manager.
3. The custom Siddhi policy groups the matching stream by its configured key.
4. When the time-batch threshold is exceeded, APIM returns `429 Too Many Requests`.
5. The `_throttle_out_handler_` sequence adds `Retry-After`, standard `RateLimit-*`, compatibility `X-RateLimit-*`, policy and correlation headers, plus an `application/problem+json` body.
6. The sequence asynchronously clones a normalized alert to the MI-managed `RuntimePolicyAlertAPI`.
7. MI validates policy, partner, API, application and correlation identity.
8. MI calls the backend Kafka bridge with a 1.5-second timeout, two bounded retries, endpoint suspension and exponential recovery.
9. The backend publishes the event to `telco.runtime.policy.alerts` in Redpanda/Kafka.

Alert publication is intentionally partial and non-blocking. If MI or Kafka is unavailable, the consumer still receives the correct 429; the alert clone cannot replace that response.

## Consumer behavior

Consumers must preserve `X-Correlation-ID`, send a stable `X-Partner-Id`, honor `Retry-After`, and use bounded exponential backoff with jitter. A 429 must not be retried immediately or bypassed through duplicate applications.

The alert contains operational identity only. It does not contain the SIM Swap MSISDN, QoD device, location or request body. Consent and legal-basis requirements for the underlying API operation remain unchanged.

## Build and start

For a clean rebuild that removes the previous APIM/bootstrap state:

```bash
COMPOSE=(docker compose \
  -f docker-compose.yml \
  -f docker-compose.kafka.yml \
  -f docker-compose.opa.yml \
  -f docker-compose.mi.yml \
  -f docker-compose.mi.soap.yml \
  -f docker-compose.observability.yml \
  -f docker-compose.runtime-persistence.yml \
  -f docker-compose.siddhi-runtime.yml)

"${COMPOSE[@]}" down -v --remove-orphans
NO_CACHE=1 ./scripts/start-siddhi-runtime-enforcement.sh
```

The start helper builds the changed images, starts the complete topology once,
waits for APIM/MI/backend health, waits for the one-shot bootstrapper to finish,
registers the MI services in Service Catalog and then starts any dependent portals.

## Verification

```bash
./scripts/verify-siddhi-runtime-enforcement.sh
```

The verifier checks policy deployment and query matching, API/Product publication, commercial policies, Developer Portal documents, QoD definition, MI Service Catalog registration, health, live 429 headers/body, and Kafka events containing partner/API/application/correlation identity.

## Postman and SDK guidance

Import `artifacts/postman/telco-siddhi-runtime-enforcement.postman_collection.json`. Obtain an OAuth token from the existing `Regional Portal` application or another subscribed application and set the collection variables. The updated public OpenAPI definitions are used by APIM for Try Out and SDK generation; generated clients still need explicit 429 retry/backoff handling.
