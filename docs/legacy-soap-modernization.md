# Legacy SOAP Billing Modernization

## Runtime flow

```text
Partner REST/JSON
      |
      v
WSO2 API Manager 4.7
  OAuth2 / lifecycle / throttling / governance
      |
      v
WSO2 Integrator: MI 4.6
  validation and correlation
  JSON -> SOAP 1.1 XML
  WS-Security UsernameToken
  SOAPAction, explicit POST and REST_URL_POSTFIX removal
  transport timeout / retry / suspension / failover
  SOAP XML -> canonical JSON
  SOAP Fault -> standard application/problem+json
      |                           |
      v                           v
Legacy BSS PRIMARY          Legacy BSS DR
```

## Resilience behavior

- Connection and timeout failures are endpoint failures. MI suspends failed endpoints immediately for the configured transport/timeout codes, and the failover endpoint selects the next eligible child.
- The first suspension is 5 seconds; progression factor 2 increases later windows up to 30 seconds.
- SOAP business faults are intentionally kept in the normal mediation sequence by setting `FORCE_ERROR_ON_SOAP_FAULT=false`. They are normalized, but they do not suspend the primary node or trigger DR processing.
- `transactionId` is the legacy idempotency key. Repeated requests return the same adjustment identifier.

## Security behavior

The demo constructs a standards-based WS-Security UsernameToken with PasswordText. Credentials are externalized as container environment variables. For production, use a secret manager and, where the BSS requires signing or encryption, replace the demo UsernameToken construction with a WS-Policy-backed endpoint and enterprise keystore/HSM configuration.

## Catalog entries

- `BillingAdjustmentModernizationAPI` — OAS3, partner-facing MI service.
- `LegacyBillingAdjustmentSOAPService` — WSDL1, underlying BSS service.
