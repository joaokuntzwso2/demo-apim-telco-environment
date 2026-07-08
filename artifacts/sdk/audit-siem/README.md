# Telco Audit Events API SDK instructions

1. In the WSO2 Developer Portal, open `TelcoAuditEventsAPI:1.0.0`.
2. Subscribe an application using an allowed plan such as `TelcoSecurityAuditBurst`.
3. Generate a production key with the client-credentials grant and request `telco_audit_write`.
4. Download an SDK from the API's **SDKs** tab or use the OpenAPI contract at `contracts/openapi/telco-audit-events.openapi.yaml` with your approved generator.
5. Always send `X-Correlation-ID`; never log access tokens or client secrets.

Example:

```bash
curl -k -X POST \
  'https://localhost:8243/audit-events/v1/1.0.0/events' \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H 'Content-Type: application/json' \
  -H 'X-Correlation-ID: audit-sdk-example-001' \
  --data @audit-event.json
```
