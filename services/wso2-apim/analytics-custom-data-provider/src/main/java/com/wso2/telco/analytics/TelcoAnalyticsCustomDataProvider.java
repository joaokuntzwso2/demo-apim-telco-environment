package com.wso2.telco.analytics;

import org.apache.synapse.MessageContext;
import org.apache.synapse.core.axis2.Axis2MessageContext;
import org.wso2.carbon.apimgt.common.analytics.collectors.AnalyticsCustomDataProvider;

import java.lang.reflect.Method;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.Locale;
import java.util.Map;

/**
 * Adds business dimensions to WSO2 API Manager's native analytics event.
 *
 * Native APIM event fields remain authoritative for API/operation, application,
 * response codes, correlation ID, request latency and backend latency. This
 * provider adds only the telco/product/commercial dimensions that are not part
 * of the standard event schema. Request/response bodies and credentials are
 * never inspected or exported.
 */
public final class TelcoAnalyticsCustomDataProvider implements AnalyticsCustomDataProvider {

    private static final String UNKNOWN = "UNKNOWN";

    private static final Map<String, String> API_PRODUCT_BY_API;

    static {
        Map<String, String> products = new LinkedHashMap<>();
        products.put("OpenGatewayNumberVerificationAPI", "OpenGatewayFraudDefenseProduct");
        products.put("OpenGatewaySimSwapRiskAPI", "OpenGatewayFraudDefenseProduct");
        products.put("OpenGatewayDeviceLocationVerificationAPI", "OpenGatewayFraudDefenseProduct");
        products.put("TelcoBusinessCatalogAPI", "DigitalCustomerBSSExperienceProduct");
        products.put("Customer360API", "DigitalCustomerBSSExperienceProduct");
        products.put("NumberLifecycleAPI", "DigitalCustomerBSSExperienceProduct");
        products.put("BillingAdjustmentSOAP", "DigitalCustomerBSSExperienceProduct");
        products.put("BillingAdjustmentModernizationAPI", "DigitalCustomerBSSExperienceProduct");
        products.put("NetworkSliceAPI", "FiveGNetworkMonetizationProduct");
        products.put("PartnerChargingAPI", "FiveGNetworkMonetizationProduct");
        products.put("NetworkEventsStreamAPI", "FiveGNetworkMonetizationProduct");
        products.put("SecureTransactionRiskAssessmentAPI", "SecureMobileTransactionsProduct");
        API_PRODUCT_BY_API = Collections.unmodifiableMap(products);
    }

    @Override
    public Map<String, Object> getCustomProperties(Object context) {
        if (!(context instanceof MessageContext)) {
            return Collections.emptyMap();
        }

        MessageContext messageContext = (MessageContext) context;
        Map<String, Object> result = new LinkedHashMap<>();
        Map<String, Object> headers = transportHeaders(messageContext);

        String apiName = firstNonBlank(
                property(messageContext, "api.ut.api"),
                property(messageContext, "api.ut.apiName"),
                property(messageContext, "API_NAME"),
                header(headers, "X-Telco-API"));
        String apiVersion = firstNonBlank(
                property(messageContext, "api.ut.api_version"),
                property(messageContext, "api.ut.version"),
                header(headers, "X-Telco-API-Version"));
        String operation = firstNonBlank(
                property(messageContext, "api.ut.resource"),
                property(messageContext, "API_ELECTED_RESOURCE"),
                property(messageContext, "REST_URL_POSTFIX"),
                header(headers, "X-Telco-Operation"));
        String method = firstNonBlank(
                property(messageContext, "api.ut.HTTP_METHOD"),
                property(messageContext, "HTTP_METHOD"),
                header(headers, "X-HTTP-Method-Override"));

        String applicationName = firstNonBlank(
                property(messageContext, "api.ut.application.name"),
                header(headers, "application-id"),
                header(headers, "X-Application-ID"),
                header(headers, "X-Telco-Application"));
        String applicationId = firstNonBlank(
                property(messageContext, "api.ut.application.id"),
                header(headers, "X-Application-UUID"),
                header(headers, "X-Telco-Application-ID"));
        String applicationOwner = firstNonBlank(
                property(messageContext, "api.ut.userId"),
                property(messageContext, "api.ut.userName"),
                property(messageContext, "api.ut.application.owner"));

        String partner = firstNonBlank(
                header(headers, "X-Partner-ID"),
                header(headers, "partner-id"),
                header(headers, "source-id"),
                applicationOwner,
                applicationName);
        String country = firstNonBlank(
                header(headers, "X-Country-Code"),
                header(headers, "country"),
                header(headers, "organization-id"),
                env("TELCO_GATEWAY_COUNTRY", "UNSPECIFIED"));
        String gateway = firstNonBlank(
                env("TELCO_GATEWAY_NAME", null),
                property(messageContext, "api.ut.hostName"),
                "wso2-apim-classic");
        String gatewayRegion = firstNonBlank(
                env("TELCO_GATEWAY_REGION", null),
                property(messageContext, "regionId"),
                "local");

        String correlationId = firstNonBlank(
                header(headers, "X-Correlation-ID"),
                header(headers, "activityID"),
                property(messageContext, "am.correlationID"),
                property(messageContext, "correlationId"));

        String subscriptionId = firstNonBlank(
                property(messageContext, "api.ut.subscription.id"),
                property(messageContext, "subscriptionId"),
                header(headers, "X-Subscription-ID"));
        String subscriptionPolicy = firstNonBlank(
                property(messageContext, "api.ut.subscription.policy"),
                property(messageContext, "api.ut.subscriptionPolicy"),
                property(messageContext, "subscriptionPolicy"),
                reflectedAuthenticationValue(messageContext, "getTier"),
                header(headers, "X-Subscription-Policy"));
        String commercialPlan = firstNonBlank(
                header(headers, "X-Commercial-Plan"),
                subscriptionPolicy,
                "UNSPECIFIED");

        String apiProduct = firstNonBlank(
                apiProductFromApiObject(messageContext),
                API_PRODUCT_BY_API.get(apiName),
                header(headers, "X-Telco-API-Product"),
                "UNASSIGNED");

        int status = integer(firstNonBlank(
                property(messageContext, "HTTP_SC"),
                property(messageContext, "HTTP_RESPONSE_STATUS_CODE"),
                property(messageContext, "api.ut.response.status"),
                property(messageContext, "axis2.HTTP_SC")), 0);
        String errorType = firstNonBlank(
                property(messageContext, "errorType"),
                property(messageContext, "ERROR_TYPE"),
                property(messageContext, "api.ut.errorType"));
        String source = firstNonBlank(header(headers, "source-id"), "");
        String outcome = classifyOutcome(status, errorType, source);

        long billableUnits = longValue(header(headers, "X-Billable-Units"),
                "SUCCESS".equals(outcome) ? 1L : 0L);

        put(result, "telcoSchemaVersion", "1.0");
        put(result, "telcoApi", apiName);
        put(result, "telcoApiVersion", apiVersion);
        put(result, "telcoOperation", operation);
        put(result, "telcoHttpMethod", method);
        put(result, "telcoPartner", partner);
        put(result, "telcoApplication", applicationName);
        put(result, "telcoApplicationId", applicationId);
        put(result, "telcoApiProduct", apiProduct);
        put(result, "telcoCountry", country);
        put(result, "telcoGateway", gateway);
        put(result, "telcoGatewayRegion", gatewayRegion);
        put(result, "telcoSubscriptionId", subscriptionId);
        put(result, "telcoSubscriptionPolicy", subscriptionPolicy);
        put(result, "telcoCommercialPlan", commercialPlan);
        put(result, "telcoCorrelationId", correlationId);
        put(result, "telcoBillableUnits", billableUnits);
        put(result, "telcoBillable", billableUnits > 0);
        put(result, "telcoTransactionOutcome", outcome);
        put(result, "telcoFailureClass", failureClass(outcome));
        put(result, "telcoPartialResponsePolicy",
                header(headers, "X-Partial-Response-Policy"));
        put(result, "telcoDataClassification", "METADATA_ONLY");
        return result;
    }

    private static String classifyOutcome(int status, String errorType, String source) {
        String normalizedError = safe(errorType).toUpperCase(Locale.ROOT);
        String normalizedSource = safe(source).toLowerCase(Locale.ROOT);

        if (status == 400 || status == 401 || status == 403 || status == 404
                || status == 405 || status == 406 || status == 415 || status == 429
                || normalizedError.contains("AUTH")
                || normalizedError.contains("THROTTL")
                || normalizedError.contains("POLICY")
                || normalizedError.contains("VALIDATION")) {
            return "REJECTED";
        }
        if (status >= 500
                || normalizedError.contains("BACKEND")
                || normalizedError.contains("ENDPOINT")
                || normalizedError.contains("CONNECT")
                || normalizedSource.contains("billing-fail")
                || normalizedSource.contains("backend-fail")) {
            return "FAILED";
        }
        return "SUCCESS";
    }

    private static String failureClass(String outcome) {
        if ("REJECTED".equals(outcome)) {
            return "GATEWAY_REJECTED";
        }
        if ("FAILED".equals(outcome)) {
            return "BACKEND_OR_BUSINESS_FAILURE";
        }
        return "NONE";
    }

    private static Map<String, Object> transportHeaders(MessageContext messageContext) {
        try {
            if (messageContext instanceof Axis2MessageContext) {
                org.apache.axis2.context.MessageContext axis2 =
                        ((Axis2MessageContext) messageContext).getAxis2MessageContext();
                Object raw = axis2.getProperty("TRANSPORT_HEADERS");
                if (raw instanceof Map) {
                    @SuppressWarnings("unchecked")
                    Map<String, Object> headers = (Map<String, Object>) raw;
                    return headers;
                }
            }
        } catch (RuntimeException ignored) {
            // The provider must never interfere with the API invocation.
        }
        return Collections.emptyMap();
    }

    private static String property(MessageContext context, String name) {
        try {
            Object value = context.getProperty(name);
            return value == null ? null : String.valueOf(value);
        } catch (RuntimeException ignored) {
            return null;
        }
    }

    private static String header(Map<String, Object> headers, String requestedName) {
        for (Map.Entry<String, Object> entry : headers.entrySet()) {
            if (entry.getKey() != null && entry.getKey().equalsIgnoreCase(requestedName)) {
                Object value = entry.getValue();
                return value == null ? null : String.valueOf(value);
            }
        }
        return null;
    }

    private static String reflectedAuthenticationValue(MessageContext context, String methodName) {
        for (String propertyName : new String[]{"API_AUTH_CONTEXT", "__API_AUTH_CONTEXT", "api.ut.authContext"}) {
            Object authContext = context.getProperty(propertyName);
            String value = invokeString(authContext, methodName);
            if (notBlank(value)) {
                return value;
            }
        }
        return null;
    }

    private static String apiProductFromApiObject(MessageContext context) {
        Object api = context.getProperty("API");
        if (api == null) {
            return null;
        }
        Object additionalProperties = invoke(api, "getAdditionalProperties");
        if (!(additionalProperties instanceof Map)) {
            return null;
        }
        @SuppressWarnings("unchecked")
        Map<Object, Object> values = (Map<Object, Object>) additionalProperties;
        for (Map.Entry<Object, Object> entry : values.entrySet()) {
            String key = String.valueOf(entry.getKey());
            if ("x-telco-api-product".equalsIgnoreCase(key)
                    || "apiProduct".equalsIgnoreCase(key)
                    || "APIProduct".equalsIgnoreCase(key)) {
                return entry.getValue() == null ? null : String.valueOf(entry.getValue());
            }
        }
        return null;
    }

    private static Object invoke(Object target, String methodName) {
        if (target == null) {
            return null;
        }
        try {
            Method method = target.getClass().getMethod(methodName);
            return method.invoke(target);
        } catch (ReflectiveOperationException | RuntimeException ignored) {
            return null;
        }
    }

    private static String invokeString(Object target, String methodName) {
        Object value = invoke(target, methodName);
        return value == null ? null : String.valueOf(value);
    }

    private static void put(Map<String, Object> target, String key, Object value) {
        if (value == null) {
            return;
        }
        if (value instanceof String && !notBlank((String) value)) {
            return;
        }
        target.put(key, value);
    }

    private static String env(String key, String fallback) {
        String value = System.getenv(key);
        return notBlank(value) ? value : fallback;
    }

    private static int integer(String value, int fallback) {
        try {
            return Integer.parseInt(safe(value).trim());
        } catch (NumberFormatException ignored) {
            return fallback;
        }
    }

    private static long longValue(String value, long fallback) {
        try {
            return Long.parseLong(safe(value).trim());
        } catch (NumberFormatException ignored) {
            return fallback;
        }
    }

    private static String firstNonBlank(String... values) {
        for (String value : values) {
            if (notBlank(value)) {
                return value.trim();
            }
        }
        return null;
    }

    private static boolean notBlank(String value) {
        return value != null && !value.trim().isEmpty() && !UNKNOWN.equalsIgnoreCase(value.trim());
    }

    private static String safe(String value) {
        return value == null ? "" : value;
    }
}
