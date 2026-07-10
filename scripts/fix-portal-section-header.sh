#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$ROOT" ] || {
  echo "Run this script from inside the repository." >&2
  exit 1
}

cd "$ROOT"

APP="services/demo-portal/public/app.js"

[ -f "$APP" ] || {
  echo "Portal application not found: $APP" >&2
  exit 1
}

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP=".portal-header-backups/$STAMP"

mkdir -p "$BACKUP"
cp "$APP" "$BACKUP/app.js"

echo "Backup created:"
echo "  $BACKUP/app.js"

python3 - <<'PY'
from pathlib import Path
import re
import sys

path = Path("services/demo-portal/public/app.js")
source = path.read_text(encoding="utf-8")

if "PORTAL_NAVIGATION_V2" in source:
    print("The consistent portal-header controller is already installed.")
    sys.exit(0)

page_copy = r"""const pageCopy = {
  overview: {
    title: 'Executive overview',
    subtitle: 'Business, network and partner API capabilities governed through WSO2 API Manager.'
  },

  customer: {
    title: 'Customer & BSS',
    subtitle: 'Consent-aware customer, subscriber and eligibility APIs for partner and care journeys.'
  },

  network: {
    title: 'Network APIs',
    subtitle: 'Network slicing, quality-on-demand and OSS telemetry as monetizable API products.'
  },

  regional: {
    title: 'Regional gateways',
    subtitle: 'Federated API runtimes operating under centralized governance and commercial controls.'
  },

  gateways: {
    title: 'Regional gateways',
    subtitle: 'Federated API runtimes operating under centralized governance and commercial controls.'
  },

  'regional-gateways': {
    title: 'Regional gateways',
    subtitle: 'Federated API runtimes operating under centralized governance and commercial controls.'
  },

  commercial: {
    title: 'Products & monetization',
    subtitle: 'API packaging, plans, quotas, usage analytics and partner settlement views.'
  },

  monetization: {
    title: 'Products & monetization',
    subtitle: 'API packaging, plans, quotas, usage analytics and partner settlement views.'
  },

  runtime: {
    title: 'Streaming & legacy',
    subtitle: 'Event-driven APIs and SOAP modernization under the same API governance model.'
  },

  streaming: {
    title: 'Streaming & legacy',
    subtitle: 'Event-driven APIs and SOAP modernization under the same API governance model.'
  },

  'open-gateway': {
    title: 'Open Gateway',
    subtitle: 'CAMARA-aligned network capabilities exposed through governed, partner-ready APIs.'
  },

  openGateway: {
    title: 'Open Gateway',
    subtitle: 'CAMARA-aligned network capabilities exposed through governed, partner-ready APIs.'
  },

  governance: {
    title: 'Governance scorecard',
    subtitle: 'Policy compliance, API quality and delivery readiness across the API portfolio.'
  },

  scorecard: {
    title: 'Governance scorecard',
    subtitle: 'Policy compliance, API quality and delivery readiness across the API portfolio.'
  },

  'governance-scorecard': {
    title: 'Governance scorecard',
    subtitle: 'Policy compliance, API quality and delivery readiness across the API portfolio.'
  },

  operations: {
    title: 'Operations workspace',
    subtitle: 'Platform readiness, runtime health and controlled operational workflows.'
  },

  'operations-workspace': {
    title: 'Operations workspace',
    subtitle: 'Platform readiness, runtime health and controlled operational workflows.'
  },

  ai: {
    title: 'AI support assistant',
    subtitle: 'Governed AI assistance with model routing, quotas, safety controls and cost attribution.'
  },

  assistant: {
    title: 'AI support assistant',
    subtitle: 'Governed AI assistance with model routing, quotas, safety controls and cost attribution.'
  },

  security: {
    title: 'Security & access control',
    subtitle: 'OAuth, consent, policy enforcement and risk-aware access controls.'
  },

  oauth: {
    title: 'OAuth & consent controls',
    subtitle: 'Identity, authorization, consent and risk controls for partner API access.'
  },

  observability: {
    title: 'Observability',
    subtitle: 'Operational telemetry, API analytics, audit evidence and runtime diagnostics.'
  },

  audit: {
    title: 'Audit & compliance',
    subtitle: 'Security events, policy decisions and traceable operational evidence.'
  }
}"""

page_pattern = re.compile(
    r"const\s+pageCopy\s*=\s*\{.*?\};"
    r"(?=\s*async\s+function\s+getJson)",
    re.DOTALL,
)

source, page_count = page_pattern.subn(
    lambda _match: page_copy,
    source,
    count=1,
)

if page_count != 1:
    raise SystemExit(
        "Could not locate the pageCopy declaration in app.js. "
        "No changes were written."
    )

navigation_controller = r"""const PORTAL_NAVIGATION_V2 = true;

let portalHeaderTab = null;
let portalNavigationObserver = null;

function humanizeTab(tab) {
  return String(tab || '')
    .replace(/^tab-/, '')
    .replace(/[-_]+/g, ' ')
    .replace(/\b\w/g, letter => letter.toUpperCase())
    .trim() || 'Platform overview';
}

function getActiveTabName() {
  const activePanel = qs('.tab-panel.active');

  if (activePanel?.id?.startsWith('tab-')) {
    return activePanel.id.slice(4);
  }

  const activeNavigation = qsa(
    '.nav-item.active[data-tab]'
  )[0];

  return activeNavigation?.dataset.tab || null;
}

function getNavigationControl(tab) {
  return qsa(
    '.nav-item[data-tab], [data-open-tab]'
  ).find(control =>
    control.dataset.tab === tab ||
    control.dataset.openTab === tab
  );
}

function resolvePageCopy(tab) {
  const explicit = pageCopy[tab];
  const control = getNavigationControl(tab);
  const panel = document.getElementById(`tab-${tab}`);

  const titleNode = panel?.querySelector(
    [
      '[data-page-title]',
      '.page-title',
      '.section-header h1',
      '.section-header h2',
      '.hero h1',
      '.hero h2'
    ].join(', ')
  );

  const subtitleNode = panel?.querySelector(
    [
      '[data-page-subtitle]',
      '.page-subtitle',
      '.section-header p',
      '.hero p',
      '.section-intro'
    ].join(', ')
  );

  const title =
    explicit?.title ||
    control?.dataset.pageTitle ||
    panel?.dataset.pageTitle ||
    titleNode?.textContent?.trim() ||
    control?.textContent?.trim() ||
    humanizeTab(tab);

  const subtitle =
    explicit?.subtitle ||
    control?.dataset.pageSubtitle ||
    panel?.dataset.pageSubtitle ||
    subtitleNode?.textContent?.trim() ||
    `Operational capabilities and governance for ${title.toLowerCase()}.`;

  return {
    title,
    subtitle
  };
}

function updatePageHeader(tab, force = false) {
  if (!tab) return;

  if (!force && portalHeaderTab === tab) {
    return;
  }

  const copy = resolvePageCopy(tab);
  const title = qs('#pageTitle');
  const subtitle = qs('#pageSubtitle');

  if (title) {
    title.textContent = copy.title;
  }

  if (subtitle) {
    subtitle.textContent = copy.subtitle;
  }

  portalHeaderTab = tab;
}

function setTab(tab) {
  if (!tab) return;

  const targetPanel = document.getElementById(
    `tab-${tab}`
  );

  /*
   * A section may be supplied by an extension script or may
   * represent a separate page. Even in that situation, refresh
   * the header rather than leaving the previous section title.
   */
  if (!targetPanel) {
    updatePageHeader(tab, true);
    return;
  }

  qsa('.nav-item[data-tab]').forEach(control => {
    const active = control.dataset.tab === tab;

    control.classList.toggle('active', active);

    if (active) {
      control.setAttribute('aria-current', 'page');
    } else {
      control.removeAttribute('aria-current');
    }
  });

  qsa('.tab-panel').forEach(panel => {
    const active = panel === targetPanel;

    panel.classList.toggle('active', active);
    panel.setAttribute(
      'aria-hidden',
      active ? 'false' : 'true'
    );
  });

  updatePageHeader(tab, true);
}

function installPortalNavigation() {
  const root = document.documentElement;

  if (root.dataset.portalNavigationV2 === 'true') {
    updatePageHeader(
      getActiveTabName() || 'overview',
      true
    );

    return;
  }

  root.dataset.portalNavigationV2 = 'true';

  /*
   * Delegated handling also covers navigation items added after
   * app.js starts, including optional portal extensions.
   *
   * Existing direct handlers can continue to run. This handler
   * checks the resulting active panel before taking action.
   */
  document.addEventListener('click', event => {
    if (!(event.target instanceof Element)) {
      return;
    }

    const control = event.target.closest(
      '.nav-item[data-tab], [data-open-tab]'
    );

    if (!control) return;

    const tab =
      control.dataset.tab ||
      control.dataset.openTab;

    if (!tab) return;

    queueMicrotask(() => {
      if (getActiveTabName() === tab) {
        updatePageHeader(tab, true);
      } else {
        setTab(tab);
      }
    });
  });

  /*
   * Some extension scripts change the active panel directly.
   * Observe those changes so the right-side header always follows
   * the section that is actually visible.
   */
  portalNavigationObserver = new MutationObserver(() => {
    const tab = getActiveTabName();

    if (tab) {
      updatePageHeader(tab);
    }
  });

  portalNavigationObserver.observe(
    document.body,
    {
      subtree: true,
      attributes: true,
      attributeFilter: ['class']
    }
  );

  updatePageHeader(
    getActiveTabName() || 'overview',
    true
  );
}

function setTabLegacyRemoved(tab) {
  setTab(tab);
}"""

set_tab_pattern = re.compile(
    r"function\s+setTab\s*\(\s*tab\s*\)\s*"
    r"\{.*?\}"
    r"(?=\s*function\s+tag)",
    re.DOTALL,
)

source, set_tab_count = set_tab_pattern.subn(
    lambda _match: navigation_controller,
    source,
    count=1,
)

if set_tab_count != 1:
    raise SystemExit(
        "Could not locate setTab() in app.js. "
        "No changes were written."
    )

wire_pattern = re.compile(
    r"function\s+wireEvents\s*\(\s*\)\s*\{"
)

source, wire_count = wire_pattern.subn(
    "function wireEvents() { installPortalNavigation(); ",
    source,
    count=1,
)

if wire_count != 1:
    raise SystemExit(
        "Could not locate wireEvents() in app.js. "
        "No changes were written."
    )

path.write_text(
    source,
    encoding="utf-8"
)

print(f"Updated: {path}")
PY

if command -v node >/dev/null 2>&1; then
  node --check "$APP"
  echo "JavaScript syntax: OK"
else
  echo "WARN: Node.js is unavailable; JavaScript validation skipped."
fi

git diff --check

echo
echo "Header-controller installation complete."
echo
echo "Changed file:"
echo "  $APP"
echo
echo "Review:"
echo "  git diff -- $APP"

if command -v docker >/dev/null 2>&1 &&
   docker compose version >/dev/null 2>&1; then

  SERVICES="$(docker compose config --services 2>/dev/null || true)"
  PORTAL_SERVICE=""

  for candidate in \
    demo-portal \
    telco-demo-portal \
    portal
  do
    if printf '%s\n' "$SERVICES" |
       grep -qx "$candidate"; then
      PORTAL_SERVICE="$candidate"
      break
    fi
  done

  if [ -n "$PORTAL_SERVICE" ]; then
    echo
    echo "Rebuilding portal service: $PORTAL_SERVICE"

    docker compose up \
      -d \
      --build \
      "$PORTAL_SERVICE"
  else
    echo
    echo "Portal service was not detected automatically."
    echo "Rebuild it using the repository's normal startup command."
  fi
fi

echo
echo "Hard-refresh the page after the container restarts:"
echo "  Command + Shift + R"
echo
echo "Rollback:"
echo "  cp '$BACKUP/app.js' '$APP'"
