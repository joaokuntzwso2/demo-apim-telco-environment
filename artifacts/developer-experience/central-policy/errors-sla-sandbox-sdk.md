# Errors, SLA, Sandbox, Postman and SDK

- Preserve `X-Correlation-ID`.
- HTTP 200 with `allow=false` is a valid policy denial.
- HTTP 503 `CENTRAL_POLICY_UPSTREAM_UNAVAILABLE` means both OPA endpoints failed.
- MI uses a 3-second timeout, bounded retry, failover and endpoint suspension.
- Advisory findings are a usable partial response.
- Use the descriptors in `central-policy-catalog.json` as sandbox data.
- Import the generated Postman collection.
- Generate client SDKs from the API in the APIM Developer Portal.
