(function () {
  'use strict';

  const STORAGE_KEY = 'telco-ai-agent-minimized';

  const explicitPanelSelectors = [
    '[data-telco-ai-agent]',
    '[data-agent-panel]',
    '#telcoAiAgent',
    '#telcoAiPanel',
    '#aiAssistant',
    '.telco-ai-agent',
    '.telco-ai-panel',
    '.ai-agent-panel',
    '.agent-panel',
    '.governed-agent',
    '.ai-assistant'
  ];

  function elementText(element) {
    if (!element) {
      return '';
    }

    if (
      element instanceof HTMLInputElement &&
      typeof element.value === 'string'
    ) {
      return element.value.trim().toLowerCase();
    }

    return String(
      element.textContent ||
      element.getAttribute('aria-label') ||
      ''
    ).trim().toLowerCase();
  }

  function findAskButton() {
    return Array.from(
      document.querySelectorAll(
        'button, [role="button"], input[type="submit"]'
      )
    ).find(function (element) {
      return elementText(element).includes(
        'ask governed agent'
      );
    });
  }

  function findPanel() {
    for (const selector of explicitPanelSelectors) {
      const panel = document.querySelector(selector);

      if (panel) {
        return panel;
      }
    }

    const askButton = findAskButton();

    if (!askButton) {
      return null;
    }

    const semanticPanel = askButton.closest(
      [
        '[class*="agent"]',
        '[class*="assistant"]',
        '[class*="chat"]',
        '[id*="agent"]',
        '[id*="assistant"]',
        '[id*="chat"]',
        'aside',
        'article',
        '.panel',
        '.card'
      ].join(',')
    );

    if (semanticPanel) {
      return semanticPanel;
    }

    /*
     * Last-resort fallback for a simple form embedded in a card.
     */
    const form = askButton.closest('form');

    if (form && form.parentElement) {
      return form.parentElement;
    }

    return askButton.parentElement;
  }

  function readStoredState() {
    try {
      return window.localStorage.getItem(
        STORAGE_KEY
      ) === 'true';
    } catch (error) {
      return false;
    }
  }

  function storeState(minimized) {
    try {
      window.localStorage.setItem(
        STORAGE_KEY,
        String(minimized)
      );
    } catch (error) {
      // Storage may be disabled; minimizing still works.
    }
  }

  function installMinimizeControl(panel) {
    if (
      !panel ||
      panel.dataset.telcoAiMinimizeReady === 'true'
    ) {
      return false;
    }

    panel.dataset.telcoAiMinimizeReady = 'true';
    panel.classList.add('telco-ai-widget');

    if (
      window.getComputedStyle(panel).position === 'static'
    ) {
      panel.style.position = 'relative';
    }

    const button = document.createElement('button');

    button.type = 'button';
    button.className = 'telco-ai-minimize-button';

    function setMinimized(minimized) {
      panel.classList.toggle(
        'is-minimized',
        minimized
      );

      button.textContent = minimized ? '□' : '−';

      button.setAttribute(
        'aria-expanded',
        String(!minimized)
      );

      button.setAttribute(
        'aria-label',
        minimized
          ? 'Expand governed agent'
          : 'Minimize governed agent'
      );

      button.title = minimized
        ? 'Expand governed agent'
        : 'Minimize governed agent';

      storeState(minimized);
    }

    button.addEventListener('click', function (event) {
      event.preventDefault();
      event.stopPropagation();

      setMinimized(
        !panel.classList.contains('is-minimized')
      );
    });

    panel.appendChild(button);

    setMinimized(readStoredState());

    return true;
  }

  function initialize() {
    return installMinimizeControl(findPanel());
  }

  if (document.readyState === 'loading') {
    document.addEventListener(
      'DOMContentLoaded',
      initialize,
      { once: true }
    );
  } else {
    initialize();
  }

  /*
   * The AI widget may be rendered dynamically after the initial page load.
   */
  const observer = new MutationObserver(function () {
    if (initialize()) {
      observer.disconnect();
    }
  });

  observer.observe(document.documentElement, {
    childList: true,
    subtree: true
  });
})();
