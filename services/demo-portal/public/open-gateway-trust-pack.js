(function () {
  const NAV_ID = 'open-gateway-nav-link';

  function addNavigationLink() {
    if (document.getElementById(NAV_ID)) {
      return;
    }

    const link = document.createElement('a');
    link.id = NAV_ID;
    link.className = 'og-nav-link';
    link.href = '/open-gateway.html';
    link.textContent = 'Open Gateway';

    const nav =
      document.querySelector('nav') ||
      document.querySelector('header nav') ||
      document.querySelector('[role="navigation"]');

    if (nav) {
      nav.appendChild(link);
      return;
    }

    const sidebar =
      document.querySelector('aside') ||
      document.querySelector('[class*="sidebar"]') ||
      document.querySelector('[class*="Side"]');

    if (sidebar) {
      sidebar.appendChild(link);
      return;
    }

    const header =
      document.querySelector('header') ||
      document.querySelector('.header') ||
      document.querySelector('[data-header]');

    if (header) {
      header.appendChild(link);
      return;
    }

    link.classList.add('og-floating-nav');
    document.body.appendChild(link);
  }

  function render() {
    addNavigationLink();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', render);
  } else {
    render();
  }

  setTimeout(render, 500);
  setTimeout(render, 1500);
  setTimeout(render, 3000);
})();
