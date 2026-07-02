# Demo Runbook: WSO2 API Manager 4.7 + Moesif-style Telco Monetization

## Positioning

This demo should not look like a generic API gateway demo. The intended message is:

> A 12-country telco needs a governed API business platform, not only runtime routing. WSO2 controls lifecycle, governance, CI/CD onboarding, products, policies, streaming APIs, SOAP modernization, and runtime choice. Moesif adds deep product analytics and API monetization visibility.

## Session 1: English technical audience

### Opening

- Show the business portal.
- Explain that the mocked estate represents BSS, OSS, charging, partner APIs, legacy SOAP, and event-driven network APIs.
- State that the same flow applies to centralized governance with country-level runtime autonomy.

### What to click

1. Open http://localhost:8080.
2. Show the KPI row: 12 markets, API products, monthly calls, API revenue.
3. Refresh Customer 360 and explain PII governance and consent.
4. Reserve a 5G slice and explain premium network monetization.
5. Show API products and monetization plans.
6. Show live network events and explain AsyncAPI/SSE/WebSocket APIM support.
7. Trigger SOAP billing adjustment and explain legacy modernization.
8. Open http://localhost:8090.
9. Run `Customer360API` pipeline: show dry-run and import-only logs.
10. Run `NetworkEventsStreamAPI` pipeline: show streaming governance.
11. Run invalid roaming API: show monetization rejection.
12. Run invalid device API: show healthcheck and operationId rejection.

### Differentiation points to say

- “This is not a manual publisher demo. It is a governed APIOps onboarding flow.”
- “The API is created only after policy validation. We are not relying on human memory.”
- “Streaming is first-class: REST, SOAP, SSE/WebSocket/WebSub can be part of the same governance model.”
- “Monetization is not only rate limiting. It is product packaging, plans, usage analytics, and partner settlement.”
- “For a 12-country telco, centralized governance with local runtime deployment is the operating model.”

## Session 2: Spanish audience

### Apertura sugerida

> La idea de esta demostración no es enseñar únicamente un gateway. La idea es enseñar cómo una telco multinacional puede operar APIs como productos comerciales: con gobierno, automatización, control de ciclo de vida, analítica, monetización y soporte para REST, SOAP y APIs de streaming.

### Frases útiles

- “Aquí estamos simulando BSS, OSS, charging, partners, legacy SOAP y eventos de red.”
- “La API no entra al API Manager hasta pasar por reglas de gobierno.”
- “Este paso representa el `dry-run` de APICTL: valida sin importar.”
- “Si falta monetización, healthcheck, ownership o clasificación de datos, la API se rechaza.”
- “Esto permite un modelo regional: gobierno centralizado y ejecución distribuida por país o dominio.”

## Negative scenarios

### RoamingQuoteAPI-MissingMonetization

Expected rejection:

- Missing `x-telco-monetization-model`.

Business explanation:

> A roaming quote API may look technically valid, but for a telco it cannot go live without commercial treatment. Is it free, bundled, billable per call, or part of a partner product?

### DeviceEligibilityAPI-MissingHealthCheck

Expected rejection:

- Missing `x-telco-healthcheck.path`.
- Missing `x-telco-healthcheck.method`.
- Missing operationId.

Business explanation:

> At country scale, operations teams need standard health checks and stable operation names for observability, support, and deployment automation.

## APICTL story

The pipeline portal shows:

```bash
apictl add env am47 --apim https://wso2-apim:9443 --token https://wso2-apim:9443/oauth2/token -k
apictl login am47 -u admin -p ******** -k
apictl import api --file <artifact> --environment am47 --dry-run -k
apictl import api --file <artifact> --environment am47 --update=true -k
```

The demo intentionally stops at import/onboarding. It does not publish and it does not deploy a revision, because this is the governance gate before runtime deployment.
