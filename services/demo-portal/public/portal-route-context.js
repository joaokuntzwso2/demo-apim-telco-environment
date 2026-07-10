(() => {
  'use strict';

  const CONTEXTS = {
    overview: {
      title: 'Executive overview',
      subtitle:
        'Business, network and partner API capabilities governed through WSO2 API Manager.'
    },

    customer: {
      title: 'Customer & BSS',
      subtitle:
        'Consent-aware customer, subscriber and eligibility APIs for partner and care journeys.'
    },

    network: {
      title: 'Network APIs',
      subtitle:
        'Network slicing, quality-on-demand and OSS telemetry as monetizable API products.'
    },

    regional: {
      title: 'Regional gateways',
      subtitle:
        'Federated API runtimes operating under centralized governance and commercial controls.'
    },

    commercial: {
      title: 'Products & monetization',
      subtitle:
        'API packaging, plans, quotas, usage analytics and partner settlement views.'
    },

    runtime: {
      title: 'Streaming & legacy',
      subtitle:
        'Event-driven APIs and SOAP modernization under the same API governance model.'
    },

    'open-gateway': {
      title: 'Open Gateway',
      subtitle:
        'CAMARA-aligned network capabilities exposed through governed, partner-ready APIs.'
    },

    'governance-scorecard': {
      title: 'Governance Scorecard',
      subtitle:
        'Policy compliance, API quality and delivery readiness across the API portfolio.'
    },

    'operations-workspace': {
      title: 'Operations Workspace',
      subtitle:
        'Platform readiness, runtime health and controlled operational workflows.'
    }
  };

  const ALIASES = {
    gateways: 'regional',
    'regional-gateways': 'regional',

    monetization: 'commercial',

    streaming: 'runtime',

    governance: 'governance-scorecard',
    scorecard: 'governance-scorecard',

    operations: 'operations-workspace',
    'demo-commander': 'operations-workspace'
  };

  const ROUTES = {
    '/open-gateway.html': 'open-gateway',
    '/governance-scorecard.html': 'governance-scorecard',
    '/operations-workspace.html': 'operations-workspace',
    '/demo-commander.html': 'operations-workspace'
  };

  /*
   * The first two selectors address the main portal topbar.
   * The remaining selectors address the standalone pages.
   */
  const TITLE_SELECTORS = [
    '#pageTitle',
    '[data-portal-page-title]',
    '.portal-page-header h1',
    '.og-page-title h1'
  ];

  const SUBTITLE_SELECTORS = [
    '#pageSubtitle',
    '[data-portal-page-subtitle]',
    '.portal-page-header p',
    '.og-page-title p'
  ];

  let lastKey = null;
  let scheduled = false;

  function normalizeKey(value) {
    const raw = String(value || '')
      .trim()
      .replace(/^#/, '')
      .replace(/^tab-/, '')
      .replace(/\.html$/, '')
      .toLowerCase();

    return ALIASES[raw] || raw;
  }

  function normalizedPathname() {
    const pathname =
      window.location.pathname.replace(/\/+$/, '');

    return pathname || '/';
  }

  function routeKey() {
    return ROUTES[normalizedPathname()] || null;
  }

  function activePanelKey() {
    const activePanel = document.querySelector(
      '.tab-panel.active[id^="tab-"]'
    );

    if (activePanel) {
      return normalizeKey(activePanel.id);
    }

    const activeControl = document.querySelector(
      '.nav-item.active[data-tab], ' +
      '[data-open-tab].active'
    );

    if (activeControl) {
      return normalizeKey(
        activeControl.dataset.tab ||
        activeControl.dataset.openTab
      );
    }

    return null;
  }

  function currentKey() {
    return (
      routeKey() ||
      activePanelKey() ||
      'overview'
    );
  }

  function setText(selectors, value) {
    const seen = new Set();

    selectors.forEach(selector => {
      document
        .querySelectorAll(selector)
        .forEach(element => {
          if (seen.has(element)) {
            return;
          }

          seen.add(element);
          element.textContent = value;
        });
    });
  }

  function keyFromControl(control) {
    if (control.dataset.tab) {
      return normalizeKey(control.dataset.tab);
    }

    if (control.dataset.openTab) {
      return normalizeKey(
        control.dataset.openTab
      );
    }

    const href =
      control.getAttribute('href');

    if (!href || href.startsWith('#')) {
      return null;
    }

    try {
      const url = new URL(
        href,
        window.location.href
      );

      if (
        url.origin !==
        window.location.origin
      ) {
        return null;
      }

      const pathname =
        url.pathname.replace(/\/+$/, '') ||
        '/';

      return ROUTES[pathname] || null;
    } catch (_error) {
      return null;
    }
  }

  function syncNavigation(key) {
    const controls =
      document.querySelectorAll(
        [
          '.nav-item',
          '.side-nav a',
          '.og-portal-nav a',
          '[data-open-tab]'
        ].join(', ')
      );

    controls.forEach(control => {
      const candidate =
        keyFromControl(control);

      if (!candidate) {
        return;
      }

      const active =
        candidate === key;

      control.classList.toggle(
        'active',
        active
      );

      if (active) {
        control.setAttribute(
          'aria-current',
          'page'
        );
      } else {
        control.removeAttribute(
          'aria-current'
        );
      }
    });
  }

  function syncContext(force = false) {
    const key =
      normalizeKey(currentKey());

    const context =
      CONTEXTS[key];

    if (!context) {
      return;
    }

    if (
      !force &&
      key === lastKey
    ) {
      return;
    }

    setText(
      TITLE_SELECTORS,
      context.title
    );

    setText(
      SUBTITLE_SELECTORS,
      context.subtitle
    );

    syncNavigation(key);

    document.body.dataset.portalSection =
      key;

    document.title =
      `${context.title} | Regional Telco API Platform`;

    lastKey = key;
  }

  function scheduleSync(force = false) {
    if (
      scheduled &&
      !force
    ) {
      return;
    }

    scheduled = true;

    window.requestAnimationFrame(() => {
      scheduled = false;
      syncContext(force);
    });
  }

  /*
   * In-page tab navigation.
   */
  document.addEventListener(
    'click',
    event => {
      if (
        !(event.target instanceof Element)
      ) {
        return;
      }

      const control =
        event.target.closest(
          '.nav-item[data-tab], ' +
          '[data-open-tab]'
        );

      if (!control) {
        return;
      }

      window.setTimeout(
        () => scheduleSync(true),
        0
      );
    },
    true
  );

  window.addEventListener(
    'hashchange',
    () => scheduleSync(true)
  );

  window.addEventListener(
    'popstate',
    () => scheduleSync(true)
  );

  function start() {
    syncContext(true);

    /*
     * Several extension scripts activate sections by directly
     * modifying class names. Observe those changes and update
     * the header from the section that is actually visible.
     */
    const observer =
      new MutationObserver(() => {
        scheduleSync(false);
      });

    observer.observe(
      document.body,
      {
        subtree: true,
        attributes: true,
        attributeFilter: ['class']
      }
    );

    window.portalRouteContext = {
      sync: () => syncContext(true),
      current: currentKey
    };
  }

  if (
    document.readyState === 'loading'
  ) {
    document.addEventListener(
      'DOMContentLoaded',
      start,
      { once: true }
    );
  } else {
    start();
  }
})();
