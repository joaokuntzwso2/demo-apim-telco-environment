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
      >> "$TMP"; \
    mv "$TMP" "$CONF"; \
    chown wso2carbon "$CONF"

USER wso2carbon
