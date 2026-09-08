(() => {
  const btn = document.getElementById('testPointsBtn');
  if (!btn) return;

  async function grant() {
    if (!confirm('Dem aktuell im selben Browser angemeldeten Steam-Spielerkonto +1000 Testpunkte geben?')) return;
    const old = btn.textContent;
    btn.disabled = true;
    btn.textContent = 'Gutschrift…';
    try {
      const res = await fetch('/api/admin/test-points', {
        method: 'POST',
        credentials: 'same-origin',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ amount: 1000 })
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
      const name = data.user?.name || 'Spielerkonto';
      const balance = Number(data.user?.points || 0).toLocaleString('de-DE');
      if (typeof toast === 'function') toast(`+1000 PTS an ${name}. Neuer Stand: ${balance} PTS.`);
      else alert(`+1000 PTS an ${name}. Neuer Stand: ${balance} PTS.`);
    } catch (err) {
      if (typeof toast === 'function') toast(err.message, true);
      else alert(err.message);
    } finally {
      btn.disabled = false;
      btn.textContent = old;
    }
  }

  btn.addEventListener('click', grant);
})();
