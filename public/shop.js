(() => {
  const $ = id => document.getElementById(id);
  let state = null;
  let busySku = null;

  async function api(url, options = {}) {
    const res = await fetch(url, {
      credentials: 'same-origin',
      headers: { 'Accept': 'application/json', 'Content-Type': 'application/json', ...(options.headers || {}) },
      ...options
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
    return data;
  }

  function toast(message, error = false) {
    const el = $('shopToast');
    if (!el) return;
    el.textContent = message;
    el.className = `shop-toast show${error ? ' error' : ''}`;
    clearTimeout(toast.timer);
    toast.timer = setTimeout(() => { el.className = 'shop-toast'; }, 3600);
  }

  function statusMeta(status) {
    if (status === 'DELIVERED') return ['ZUGESTELLT', 'delivered'];
    if (status === 'DELIVERING') return ['WIRD ZUGESTELLT', 'delivering'];
    if (status === 'FAILED_REFUNDED') return ['ERSTATTET', 'failed'];
    if (status === 'PAYMENT_RESERVED') return ['VORBEREITET', 'waiting'];
    return ['WARTET', 'waiting'];
  }

  function deliveryDetail(order) {
    if (order.status === 'DELIVERED') return `Zugestellt ${formatDate(order.fulfilledAt)}`;
    if (order.status === 'FAILED_REFUNDED') return 'Die Zustellung war dauerhaft nicht möglich. Deine Punkte wurden automatisch zurückgebucht.';
    if (order.status === 'DELIVERING') return 'Dein Gegenstand wird gerade an deinen Charakter übergeben.';
    if (order.status === 'PAYMENT_RESERVED') return 'Kauf bestätigt. PalPanel bereitet die Zustellung vor.';

    const raw = String(order.lastError || '').toLowerCase();
    if (!raw) return 'PalPanel wartet auf den richtigen Moment und versucht die Zustellung automatisch erneut.';

    if (raw.includes('nullptr') || raw.includes('uobject instance') || raw.includes('additem_serverinternal') || raw.includes('inventory unavailable')) {
      return 'Dein Charakter ist noch nicht vollständig spielbereit. Die Zustellung wird automatisch erneut versucht.';
    }
    if (raw.includes('player not found') || raw.includes('spieler aktuell nicht online') || raw.includes('not online')) {
      return 'Du bist gerade nicht auf dem Gameserver. Dein Kauf wird automatisch zugestellt, sobald du wieder verbunden bist.';
    }
    if (raw.includes('charakter nicht verknüpft') || raw.includes('character not linked')) {
      return 'Dein Palworld-Charakter muss noch mit PalPanel verbunden werden, bevor die Zustellung erfolgen kann.';
    }
    if (raw.includes('bridge') || raw.includes('timeout') || raw.includes('gameserver') || raw.includes('beschäftigt') || raw.includes('busy')) {
      return 'Der Gameserver ist gerade noch nicht bereit für die Zustellung. PalPanel versucht es automatisch erneut.';
    }
    return 'Die Zustellung braucht gerade etwas länger. PalPanel versucht es automatisch erneut — du musst nichts tun.';
  }

  function formatDate(value) {
    if (!value) return '—';
    const d = new Date(value);
    if (Number.isNaN(d.getTime())) return '—';
    return d.toLocaleString('de-DE', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' });
  }

  function categoryForSku(sku) {
    const value = String(sku || '');
    if (value.startsWith('spheres-')) return { key: 'spheres', label: 'SPHÄREN', title: 'Fang-Ausrüstung', hint: 'Vom Alltagsvorrat bis zur seltenen Sphäre für die späte Spielphase.' };
    if (value.startsWith('ammo-')) return { key: 'ammo', label: 'MUNITION', title: 'Nachschub für Kämpfe', hint: 'Praktische Verbrauchspakete, ohne Waffenfortschritt zu überspringen.' };
    if (value.startsWith('supply-')) return { key: 'supply', label: 'VERSORGUNG', title: 'Medizin & Verpflegung', hint: 'Hilfreiche Vorräte für Expedition, Basis und Zucht.' };
    if (value.startsWith('materials-')) return { key: 'materials', label: 'MATERIALIEN', title: 'Werkstoffe', hint: 'Zeitsparender Materialschub, seltene Ressourcen bleiben entsprechend teuer.' };
    return { key: 'other', label: 'WEITERES', title: 'Weitere Angebote', hint: 'Zusätzliche Server-Gegenstände.' };
  }

  function renderCard(item, category) {
    const affordable = Number(state.points || 0) >= Number(item.price || 0);
    const enabled = state.linked && affordable && busySku !== item.sku;
    const label = busySku === item.sku ? 'WIRD GEKAUFT…' : !state.linked ? 'CHARAKTER FEHLT' : !affordable ? 'ZU WENIG PUNKTE' : 'KAUFEN';
    return `<article class="shop-card${affordable ? '' : ' cannot-afford'}">
      <div class="card-top"><span class="card-tag">${category.label}</span><span class="quantity">× ${Number(item.quantity || 1)}</span></div>
      <h3>${escapeHtml(item.name)}</h3>
      <p>${escapeHtml(item.description)}</p>
      <div class="shop-buy-row"><div class="shop-price"><small>PREIS</small><strong>${Number(item.price || 0).toLocaleString('de-DE')} PUNKTE</strong></div><button class="shop-buy" data-sku="${escapeAttr(item.sku)}" ${enabled ? '' : 'disabled'}>${label}</button></div>
    </article>`;
  }

  function renderCatalog() {
    const root = $('shopCatalog');
    if (!root) return;
    const catalog = state?.catalog || [];
    if (!catalog.length) {
      root.innerHTML = '<div class="shop-loading">Aktuell sind keine Artikel freigeschaltet.</div>';
      return;
    }

    const order = ['spheres', 'ammo', 'supply', 'materials', 'other'];
    const groups = new Map();
    for (const item of catalog) {
      const category = categoryForSku(item.sku);
      if (!groups.has(category.key)) groups.set(category.key, { category, items: [] });
      groups.get(category.key).items.push(item);
    }

    root.innerHTML = order.filter(key => groups.has(key)).map(key => {
      const group = groups.get(key);
      return `<section class="shop-category" data-category="${group.category.key}">
        <div class="shop-category-head"><div><span>${group.category.label}</span><h3>${group.category.title}</h3></div><p>${group.category.hint}</p></div>
        <div class="shop-category-grid">${group.items.map(item => renderCard(item, group.category)).join('')}</div>
      </section>`;
    }).join('');

    root.querySelectorAll('[data-sku]').forEach(btn => btn.addEventListener('click', () => purchase(btn.dataset.sku)));
  }

  function renderOrders() {
    const root = $('shopOrders');
    if (!root) return;
    const orders = state?.orders || [];
    const open = orders.filter(o => !['DELIVERED', 'FAILED_REFUNDED'].includes(o.status)).length;
    $('queueBadge').textContent = `${open} OFFEN`;
    if (!orders.length) {
      root.innerHTML = '<div class="order-empty">Noch keine Bestellungen.</div>';
      return;
    }
    root.innerHTML = orders.map(order => {
      const [label, cls] = statusMeta(order.status);
      const detail = deliveryDetail(order);
      return `<article class="order-row"><div class="order-main"><strong>${escapeHtml(order.name || order.sku || 'Shop-Artikel')} × ${Number(order.quantity || 1)}</strong><small>${formatDate(order.createdAt)} · #${escapeHtml(String(order.orderKey || '').slice(0, 8))}</small></div><div class="order-price">-${Number(order.price || 0).toLocaleString('de-DE')} Punkte</div><div class="order-state"><b class="${cls}">${label}</b><small>${escapeHtml(detail)}</small></div></article>`;
    }).join('');
  }

  function render() {
    $('shopPoints').textContent = Number(state?.points || 0).toLocaleString('de-DE');
    $('shopLinkWarning')?.classList.toggle('hidden', !!state?.linked);
    renderCatalog();
    renderOrders();
  }

  async function refresh() {
    try {
      state = await api('/api/shop/me');
      $('shopGate')?.classList.add('hidden');
      $('shopData')?.classList.remove('hidden');
      render();
    } catch (err) {
      if (/Nicht angemeldet/i.test(err.message)) {
        $('shopGate')?.classList.remove('hidden');
        $('shopData')?.classList.add('hidden');
      } else toast(err.message, true);
    }
  }

  async function purchase(sku) {
    if (busySku) return;
    const item = state?.catalog?.find(x => x.sku === sku);
    if (!item) return;
    if (!confirm(`${item.name} für ${Number(item.price).toLocaleString('de-DE')} Punkte kaufen?`)) return;
    busySku = sku;
    renderCatalog();
    try {
      const result = await api('/api/shop/orders', { method: 'POST', body: JSON.stringify({ sku }) });
      state.points = result.points;
      state.orders = [result.order, ...(state.orders || []).filter(o => o.orderKey !== result.order.orderKey)];
      if (result.order.status === 'DELIVERED') toast('Kauf erfolgreich — Gegenstand wurde direkt zugestellt.');
      else toast('Kauf erfolgreich — die Zustellung läuft automatisch im Hintergrund.');
      render();
      window.PalAccount?.refresh?.();
    } catch (err) {
      toast(err.message, true);
    } finally {
      busySku = null;
      renderCatalog();
    }
  }

  function escapeHtml(value) {
    return String(value ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  }
  function escapeAttr(value) { return escapeHtml(value); }

  $('shopRelink')?.addEventListener('click', async () => {
    const btn = $('shopRelink');
    btn.disabled = true;
    btn.textContent = 'PRÜFE…';
    try {
      await api('/api/user/relink', { method: 'POST', body: '{}' });
      await refresh();
      window.PalAccount?.refresh?.();
      toast(state?.linked ? 'Charakter verbunden.' : 'Charakter noch nicht auf dem Server gefunden.', !state?.linked);
    } catch (err) { toast(err.message, true); }
    btn.disabled = false;
    btn.textContent = 'Server prüfen ↻';
  });

  refresh();
  setInterval(() => {
    if (document.visibilityState !== 'visible' || busySku) return;
    const open = state?.orders?.some(o => !['DELIVERED', 'FAILED_REFUNDED'].includes(o.status));
    if (open) refresh();
  }, 5000);
})();
