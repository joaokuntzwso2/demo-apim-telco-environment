FROM wso2/wso2am:4.7.0

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
      'enable = false' \
      'starting_delay = 600' \
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

# BEGIN TELCO APIM OBSERVABILITY
COPY services/wso2-apim/merge-observability-config.sh /tmp/merge-apim-observability-config.sh
RUN chmod +x /tmp/merge-apim-observability-config.sh \
    && /tmp/merge-apim-observability-config.sh /home/wso2carbon/wso2am-4.7.0/repository/conf/deployment.toml \
    && rm -f /tmp/merge-apim-observability-config.sh
# END TELCO APIM OBSERVABILITY
USER wso2carbon
