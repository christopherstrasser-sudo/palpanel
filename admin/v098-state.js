(() => {
  function syncAuthState() {
    const adminView = document.getElementById('adminView');
    const authenticated = !!adminView && !adminView.classList.contains('hidden');
    document.body.classList.toggle('admin-authenticated', authenticated);
    document.body.classList.toggle('admin-login-mode', !authenticated);
    document.body.classList.remove('admin-auth-checking');
  }

  function decorateLogin() {
    const card = document.getElementById('loginView');
    if (!card || card.querySelector('.admin-login-brand')) return;
    const brand = document.createElement('div');
    brand.className = 'admin-login-brand';
    brand.innerHTML = '<span class="login-mark">P</span><div><strong>PalPanel</strong><small>SECURE ADMIN ACCESS</small></div>';
    card.prepend(brand);
    const security = document.createElement('div');
    security.className = 'admin-login-security';
    security.innerHTML = '<i></i><span>Lokaler Verwaltungszugang · Navigation und Serverfunktionen werden erst nach erfolgreicher Anmeldung freigeschaltet.</span>';
    card.appendChild(security);
  }

  function enhanceLoginButton() {
    const form = document.getElementById('loginForm');
    const button = form?.querySelector('button[type="submit"],button:not([type])');
    if (!form || !button || form.dataset.v098Bound) return;
    form.dataset.v098Bound = '1';
    form.addEventListener('submit', () => {
      const original = button.textContent;
      button.disabled = true;
      button.textContent = 'Anmeldung wird geprüft…';
      const restore = () => {
        if (!document.body.classList.contains('admin-authenticated')) {
          button.disabled = false;
          button.textContent = original;
        }
      };
      setTimeout(restore, 900);
      setTimeout(restore, 2200);
    });
  }

  function start() {
    document.body.classList.add('admin-auth-checking');
    decorateLogin();
    enhanceLoginButton();
    const adminView = document.getElementById('adminView');
    if (adminView) new MutationObserver(syncAuthState).observe(adminView, { attributes:true, attributeFilter:['class'] });
    syncAuthState();
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start, { once:true });
  else start();
})();
