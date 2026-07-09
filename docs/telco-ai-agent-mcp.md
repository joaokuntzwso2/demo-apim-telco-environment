# Optional telco support assistant and MCP

This chapter stays optional; the main demo remains API governance, products, commercial plans, monetization and observability.

`TelcoSupportAssistantAPI` is a native WSO2 Integrator: MI agent. Its four OpenAPI tools call `TelcoAgentToolsAPI` through APIM with OAuth scopes; they do not call BSS/OSS directly. APIM publishes the two APIs, the **Telco AI Service Care Pack**, and `TelcoOperationsMCP`, all subscribed to the existing **Regional Portal** application.

Controls: APIM request and native AI token policy; MI per-partner daily token ledger; standard/advanced model routing; pre-LLM masking; prompt-injection rejection; native token counts; configurable USD cost attribution; correlation propagation; normalized errors; bounded read retries; no automatic retries for QoD/ticket writes; endpoint suspension.

Scopes: `telco_ai_support`, `telco_subscriber_status`, `telco_outage_read`, `telco_qod_request`, `telco_ticket_create`.

Sandbox: subscriber `5511999999999`, outage `OUT-2026`, QoD 60–3600 seconds, ticket severities LOW/MEDIUM/HIGH/CRITICAL.

Consent: send only the minimum synthetic data required. Masking is defense in depth, not a substitute for lawful purpose, consent and data minimization. The demo has no production SLA. Use `X-Correlation-ID` for support.

Import `artifacts/postman/telco-ai-agent-mcp.postman_collection.json`, or generate SDKs from the two OpenAPI files under `contracts/openapi/`.
