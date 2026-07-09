# Telco WSO2 API Manager 4.7 Demo Kit

This kit provides a runnable, containerized demo environment for a multinational telco bid. It includes:

- A mock BSS/OSS backend with REST, SOAP, SSE, WebSocket, and WebHook-style endpoints.
- A telco business portal to simulate CRM, partner APIs, usage, monetization, and live network events.
- A CI/CD pipeline portal that validates API governance rules, shows APICTL command logs, approves compliant APIs, rejects non-compliant APIs, and imports compliant APIs into APIM when APIM is running.
- Official WSO2 APIM 4.7 Docker service as an optional profile.
- API contracts for all portal-backed capabilities.

## Fast start with legacy docker-compose

From the project root:

```bash
./scripts/run-demo.sh
```

Or detached:

```bash
./scripts/run-demo-detached.sh
```

Open:

- Telco demo portal: http://localhost:8080
- API pipeline portal: http://localhost:8090
- Mock backend health: http://localhost:8081/health

## Run with local WSO2 APIM 4.7

```bash
./scripts/run-with-apim.sh
```

Or detached:

```bash
./scripts/run-with-apim-detached.sh
```

Open APIM Publisher with `admin/admin`:

- https://localhost:9443/publisher
- https://localhost:9443/devportal

The pipeline portal now defaults to `APIM_MODE=auto`:

- If APIM is not reachable, it simulates the import but still shows the APICTL dry-run/import commands.
- If APIM is reachable and `apictl` is installed in the pipeline container, it runs real APICTL import.
- Real import uses `--dry-run` first, then `--update=true --skip-deployments` so the API is created/updated as an APIM working copy only. It does not publish and it does not deploy a gateway revision.

## Contracts

Top-level API contracts are in:

```text
contracts/
  openapi/
  asyncapi/
  soap/
```

Pipeline-ready copies are in:

```text
artifacts/contracts/
  openapi/
  asyncapi/
  soap/
```

Included contracts:

- `TelcoBusinessCatalogAPI` — portal metadata, countries, partners, products, monetization plans.
- `Customer360API` — profile, consent, subscriber eligibility.
- `NumberLifecycleAPI` — number portability, device eligibility, roaming quote.
- `NetworkSliceAPI` — 5G slice catalog, reservation, cell status.
- `PartnerChargingAPI` — usage summary, partner settlement, monetization summaries.
- `BillingAdjustmentSOAP` — SOAP/WSDL backend with APIM-importable OpenAPI façade.
- `NetworkEventsStreamAPI` — AsyncAPI streaming contract plus APIM-importable OpenAPI façade for SSE/WebHook usage.
- Two invalid APIs for rejection scenarios.

## Pipeline backlog behavior

After a pipeline reaches a final business result, the API disappears from the selectable backlog:

- `APPROVED_IMPORTED`
- `APPROVED_IMPORTED_SIMULATED`
- `REJECTED`

Technical failures, such as APIM being unreachable in forced real mode, remain selectable so the demo can be rerun after fixing the runtime.

Use **Reset backlog** in the pipeline portal to make all APIs available again.

## Useful scripts

```bash
./scripts/run-demo.sh             # foreground, auto mode
./scripts/run-demo-detached.sh    # detached/background containers
./scripts/run-with-apim.sh        # includes optional WSO2 APIM 4.7 profile
./scripts/run-with-apim-detached.sh
./scripts/stop-demo.sh            # stop containers
./scripts/reset-demo.sh           # full reset, including volume and local compose images
./scripts/curl-smoke-test.sh      # smoke-test mock backend APIs
```

## Real APICTL behavior

The pipeline container tries to download API Controller 4.7.0 during image build. If the build host cannot reach GitHub, the image still builds, but real import will fail clearly until `apictl` is mounted or installed.

APICTL sequence used by the pipeline:

```bash
apictl add env am47 --apim https://wso2-apim:9443 --token https://wso2-apim:9443/oauth2/token -k
apictl login am47 -u admin -p ******** -k
apictl init <api-project> --oas <openapi-contract> --definition <definition.yaml> --force=true
apictl import api --file <api-project> --environment am47 --dry-run -k
apictl import api --file <api-project> --environment am47 --update=true --skip-deployments -k
```

## Demo narrative

1. Show APIs across BSS, OSS, charging, number lifecycle, customer consent, partner settlement, device eligibility, and network slicing.
2. Show REST, SOAP/WSDL, and event-driven API styles.
3. Show streaming API scenarios with SSE/WebSocket/AsyncAPI for network alarm, slice utilization, and charging events.
4. Show API products and commercial packaging.
5. Show monetization plans and usage/revenue mock analytics.
6. Move to the pipeline portal and select a compliant API.
7. Run governance validation and show the dry-run/import APICTL logs.
8. Select a non-compliant API and show exactly why it is rejected.
9. Refresh the catalog to show that processed APIs disappear from the backlog.
10. Close with the value: centralized governance, APIOps, runtime flexibility, streaming API support, and monetization-ready analytics.

## macOS / Docker Desktop note

This kit does **not** bind-mount `./artifacts` from your Mac by default. The pipeline artifacts are copied into the `pipeline-portal` image during build, and pipeline state is stored in a Docker-managed volume. This avoids common macOS permission issues when running from `~/Downloads`.

If you change files under `artifacts/` or `contracts/`, rebuild:

```bash
docker-compose build pipeline-portal
docker-compose up
```

<!-- BEGIN SIDDHI RUNTIME ENFORCEMENT -->
## Runtime Siddhi business controls

The SIM Swap fair-use and Quality-on-Demand assurance policies are attached to the live APIM request stream and demonstrate normalized HTTP 429 responses, `Retry-After`/rate-limit headers, MI-mediated Kafka alerts and partner/API/application/correlation evidence.

- Architecture, consumer guidance and commands: [`docs/siddhi-runtime-enforcement.md`](docs/siddhi-runtime-enforcement.md)
- Start helper: `./scripts/start-siddhi-runtime-enforcement.sh`
- Full verification: `./scripts/verify-siddhi-runtime-enforcement.sh`
- Postman collection: `artifacts/postman/telco-siddhi-runtime-enforcement.postman_collection.json`
<!-- END SIDDHI RUNTIME ENFORCEMENT -->

<!-- BEGIN TELCO LIVE MOESIF ANALYTICS -->
## Live Gateway analytics with Moesif

The opt-in `docker-compose.moesif.yml` overlay enables WSO2 API Manager 4.7's native Moesif publisher and a WSO2 analytics custom-data provider for partner, API Product, country/Gateway, subscription/commercial plan, billable units and transaction outcome. The existing APIM → MI → backend → Kafka/Prometheus/Loki/Tempo architecture remains unchanged.

See `docs/live-gateway-moesif-analytics.md` for configuration, privacy, startup and end-to-end verification. Import `artifacts/postman/telco-live-moesif-analytics.postman_collection.json` for the successful, failed and rejected demonstration calls.
<!-- END TELCO LIVE MOESIF ANALYTICS -->



## Optional governed telco AI assistant and MCP

Adds an MI-native agent, APIM-governed OpenAPI tools, an APIM 4.7 MCP server, token controls, safeguards, cost attribution and a portal widget. See `docs/telco-ai-agent-mcp.md`.

```bash
cp .env.ai.example .env.ai.local
# Set OPENAI_API_KEY
./scripts/reset-with-telco-ai.sh
```
