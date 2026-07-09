FROM wso2/wso2am:4.7.0 AS telco-apim-runtime
USER root

RUN set -eux; \
    CONF="/home/wso2carbon/wso2am-4.7.0/repository/conf/deployment.toml"; \
    TMP="/tmp/deployment.toml"; \
    awk 'BEGIN { skip=0 } /^\[(database\.apim_db\.pool_options|database\.shared_db\.pool_options|indexing|monitoring\.jmx)\]$/ { skip=1; next } /^\[/ { skip=0 } !skip { print }' "$CONF" > "$TMP"; \
    printf '%s\n' \
      '' \
      '# ---------------------------------------------------------------------' \
      '# Local demo tuning for Colima / laptop execution.' \
      '# Not intended as a production deployment profile.' \
      '# ---------------------------------------------------------------------' \
      '' \
      '[indexing]' \
      'enable = true' \
      'starting_delay = 10' \
      'frequency = 60' \
      'batch_size = 5' \
      'pool_size = 1' \
      '' \
      '[database.apim_db.pool_options]' \
      'maxActive = 120' \
      'maxWait = 120000' \
      'testOnBorrow = true' \
      'validationQuery = "SELECT 1"' \
      'validationInterval = 30000' \
      'defaultAutoCommit = true' \
      'removeAbandoned = true' \
      'removeAbandonedTimeout = 60' \
      '' \
      '[database.shared_db.pool_options]' \
      'maxActive = 120' \
      'maxWait = 120000' \
      'testOnBorrow = true' \
      'validationQuery = "SELECT 1"' \
      'validationInterval = 30000' \
      'defaultAutoCommit = true' \
      'removeAbandoned = true' \
      'removeAbandonedTimeout = 60' \
      '' \
      '[monitoring.jmx]' \
      'rmi_server_start = false' \
       \
  '' \
  '# BEGIN TELCO DEMO MONETIZATION PROPERTIES' \
  '# Demo-only API-level monetization attributes shown in Publisher → Monetization.' \
  '[[apim.monetization.additional_attributes]]' \
  'name = "ConnectedAccountKey"' \
  'display_name = "Connected Account Key"' \
  'required = "false"' \
  'description = "Demo billing or settlement account reference for the API publisher."' \
  '' \
  '[[apim.monetization.additional_attributes]]' \
  'name = "RevenueShareModel"' \
  'display_name = "Revenue Share Model"' \
  'required = "false"' \
  'description = "Commercial revenue model used for this API product."' \
  '' \
  '[[apim.monetization.additional_attributes]]' \
  'name = "SettlementOwner"' \
  'display_name = "Settlement Owner"' \
  'required = "false"' \
  'description = "Internal owner responsible for settlement and reconciliation."' \
  '' \
  '[[apim.monetization.additional_attributes]]' \
  'name = "ProductLine"' \
  'display_name = "Product Line"' \
  'required = "false"' \
  'description = "Commercial product family for reporting and catalog grouping."' \
  '' \
  '[[apim.monetization.additional_attributes]]' \
  'name = "BillingCatalogReference"' \
  'display_name = "Billing Catalog Reference"' \
  'required = "false"' \
  'description = "External catalog, SKU, or pricing reference used for billing."' \
  '# END TELCO DEMO MONETIZATION PROPERTIES' \
  >> "$TMP"; \
    mv "$TMP" "$CONF"; \
    chown wso2carbon "$CONF"

# BEGIN TELCO APIM DEVELOPER EXPERIENCE
COPY services/wso2-apim/merge-developer-experience-config.sh /tmp/merge-apim-developer-experience-config.sh
RUN chmod +x /tmp/merge-apim-developer-experience-config.sh \
    && /tmp/merge-apim-developer-experience-config.sh /home/wso2carbon/wso2am-4.7.0/repository/conf/deployment.toml \
    && rm -f /tmp/merge-apim-developer-experience-config.sh
# END TELCO APIM DEVELOPER EXPERIENCE
# BEGIN TELCO APIM OBSERVABILITY
COPY services/wso2-apim/merge-observability-config.sh /tmp/merge-apim-observability-config.sh
RUN chmod +x /tmp/merge-apim-observability-config.sh \
    && /tmp/merge-apim-observability-config.sh /home/wso2carbon/wso2am-4.7.0/repository/conf/deployment.toml \
    && rm -f /tmp/merge-apim-observability-config.sh
# END TELCO APIM OBSERVABILITY
# BEGIN TELCO SIDDHI RUNTIME ENFORCEMENT
RUN mkdir -p /home/wso2carbon/wso2am-4.7.0/repository/deployment/server/synapse-configs/default/sequences
COPY services/wso2-apim/sequences/_throttle_out_handler_.xml /home/wso2carbon/wso2am-4.7.0/repository/deployment/server/synapse-configs/default/sequences/_throttle_out_handler_.xml
RUN chown wso2carbon /home/wso2carbon/wso2am-4.7.0/repository/deployment/server/synapse-configs/default/sequences/_throttle_out_handler_.xml  && chmod 0644 /home/wso2carbon/wso2am-4.7.0/repository/deployment/server/synapse-configs/default/sequences/_throttle_out_handler_.xml
# END TELCO SIDDHI RUNTIME ENFORCEMENT

# BEGIN TELCO APIM OAUTH BUSINESS CONTROLS
COPY services/wso2-apim/merge-oauth-business-controls-config.sh /tmp/merge-oauth-business-controls-config.sh
RUN chmod +x /tmp/merge-oauth-business-controls-config.sh \
 && /tmp/merge-oauth-business-controls-config.sh /home/wso2carbon/wso2am-4.7.0/repository/conf/deployment.toml \
 && rm -f /tmp/merge-oauth-business-controls-config.sh
# END TELCO APIM OAUTH BUSINESS CONTROLS
USER wso2carbon

# BEGIN TELCO LIVE MOESIF ANALYTICS
FROM eclipse-temurin:21-jdk-jammy AS telco-moesif-provider-builder
COPY --from=telco-apim-runtime /home/wso2carbon/wso2am-4.7.0/repository/components /opt/apim-components
COPY services/wso2-apim/analytics-custom-data-provider/src/main/java /src
RUN set -eux; \
    mkdir -p /classes; \
    find /opt/apim-components -type f -name '*.jar' -print | paste -sd: - > /tmp/classpath; \
    javac --release 21 -encoding UTF-8 -cp "$(cat /tmp/classpath)" -d /classes $(find /src -type f -name '*.java' -print); \
    jar --create --file /telco-analytics-custom-data-provider.jar -C /classes .

FROM telco-apim-runtime AS telco-apim-final
ARG ENABLE_MOESIF_ANALYTICS=false
USER root
COPY --from=telco-moesif-provider-builder /telco-analytics-custom-data-provider.jar /home/wso2carbon/wso2am-4.7.0/repository/components/lib/telco-analytics-custom-data-provider.jar



# BEGIN TELCO APIM LOCAL CONFIG PERMISSIONS
USER root

RUN chown -R wso2carbon:wso2 \
      /home/wso2carbon/wso2am-4.7.0/repository/conf \
    && find \
      /home/wso2carbon/wso2am-4.7.0/repository/conf \
      -type d \
      -exec chmod 775 {} \; \
    && chmod 664 \
      /home/wso2carbon/wso2am-4.7.0/repository/conf/deployment.toml

# END TELCO APIM LOCAL CONFIG PERMISSIONS

USER wso2carbon
# END TELCO LIVE MOESIF ANALYTICS
