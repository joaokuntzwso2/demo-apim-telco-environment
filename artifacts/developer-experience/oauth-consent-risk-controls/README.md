# OAuth scopes, roles, consent and risk-based authorization

## Responsibility split

- **WSO2 API Manager 4.7** validates the access token, subscription, commercial plan and operation scope.
- **WSO2 Integrator: MI** receives APIM's gateway-issued backend JWT and enforces persona, country, partner isolation, consent, purpose and data masking.
- **Existing MI risk/commercial APIs** continue to perform their native mediation, failover, suspension, bounded retry, normalized fault and partial-response behavior.
- **Observability** uses the incoming `X-Correlation-ID` across APIM, MI and downstream controls.

## Personas

| Sandbox user | Role | Business identity |
|---|---|---|
| `partner.alpha` | `telco_partner` | partner-alpha / BR |
| `partner.beta` | `telco_partner` | partner-beta / MX |
| `telco.operations` | `telco_operations` | operator risk operations |
| `telco.product` | `telco_product_manager` | product and commercial management |
| `telco.admin` | `telco_platform_admin` | platform administration |

Passwords and the partner, operations and short-lived OAuth client credentials are demo-only and are written to `/workspace/state/oauth-business-controls.json` inside the bootstrap state volume.

## Consent and purpose

- `CONSENT-ALPHA-001` covers partner-alpha, BR and `+5511999990001`.
- `CONSENT-BETA-001` covers partner-beta, MX and `+525512340001`.
- Subscriber operations require an allowed purpose.
- Partner responses always mask the subscriber number.
- Full data is reserved for operations/platform administrators using purpose `fraud-investigation` plus `X-Data-Access: FULL`.

## Consumer tooling

Import `artifacts/postman/oauth-consent-risk-controls.postman_collection.json`.
The verification script demonstrates token generation and all required positive/negative cases.
For generated SDKs, publish the API, open it in the Developer Portal and use the API's **SDKs** tab; the OpenAPI definition contains the OAuth scopes and operation security declarations.
