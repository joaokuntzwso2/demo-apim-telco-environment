# Postman and SDK usage

Import `artifacts/developer-experience/secure-mobile-transactions/Secure-Mobile-Transactions.postman_collection.json`. Set `gatewayUrl`, `accessToken` and `partnerId`, then run plan assignment, usage seeding, the three transaction calls and usage summary.

The OpenAPI document is available in the Developer Portal for SDK generation. Generated clients must add `Authorization: Bearer ...`, preserve or create `X-Correlation-ID`, and treat HTTP 422 as a rated rejection rather than a transport error.
