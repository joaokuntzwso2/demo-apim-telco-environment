# Secure Mobile Transactions — commercial flow

The product bundles Number Verification, SIM Swap and Quality on Demand behind one commercial contract. Every invocation carries a partner identifier and correlation identifier. WSO2 API Manager enforces OAuth, subscriptions and technical rate limits. WSO2 Integrator: MI resolves the partner plan, invokes the capability, applies the commercial rating rule and persists an idempotent usage event.

Usage is queryable by `partnerId` and `SecureMobileTransactionsProduct`. Responses include the selected plan, included allowance, over-limit state, meter, country, currency, unit price, billed amount, charge type and SLA entitlement.
