/* SaveVision HUD for Meta Ray-Ban Display Web Apps.

   Inputs:
   - Backend live case stream: savevision.html?api=http://host:8080&caseId=C-10
   - Dev bridge: BroadcastChannel('savevision-hud').postMessage(payload)
   - Dev bridge: localStorage.setItem('savevision.hud', JSON.stringify(payload))

   Payloads are the same shapes as PROTOCOL.md:
   {kind:'guidance', text:'...'}, {kind:'image', dataUrl|url, caption},
   {kind:'map', label, bearing}, {kind:'clear'}, plus backend location.updated.
*/
(() => {
  const qs = new URLSearchParams(location.search);
  const api = (qs.get('api') || '').replace(/\/$/, '');
  const caseId = qs.get('caseId') || qs.get('case');
  const els = {
    state: document.getElementById('state'), case: document.getElementById('case'),
    card: document.getElementById('card'), kind: document.getElementById('kind'),
    message: document.getElementById('message'), image: document.getElementById('image'),
    location: document.getElementById('location'), locLabel: document.getElementById('locLabel'),
    coords: document.getElementById('coords'), arrow: document.getElementById('arrow'),
    hudmap: document.getElementById('hudmap'),
  };
  let map = null, marker = null;
  function showMap(lat, lng, zoom = 16) {
    const a = Number(lat), b = Number(lng);
    if (!window.L || !Number.isFinite(a) || !Number.isFinite(b)) return;
    els.hudmap.hidden = false;
    if (!map) {
      map = L.map(els.hudmap, { zoomControl: false, attributionControl: true, dragging: false, scrollWheelZoom: false }).setView([a, b], zoom);
      L.tileLayer('https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png', { maxZoom: 19 }).addTo(map);
      marker = L.marker([a, b]).addTo(map);
    } else {
      map.setView([a, b], zoom); marker.setLatLng([a, b]);
    }
    setTimeout(() => map.invalidateSize(), 60);
  }

  function setState(text) { els.state.textContent = text; }
  function setCase(text) { els.case.textContent = text; }
  function isUrgent(text) { return /\b(stop|unsafe|danger|take cover|do not)\b/i.test(text || ''); }
  function resetMedia() { els.image.hidden = true; els.location.hidden = true; els.arrow.hidden = true; els.hudmap.hidden = true; }
  function pulse() { els.card.classList.remove('toast'); void els.card.offsetWidth; els.card.classList.add('toast'); }

  function render(payload = {}) {
    const kind = (payload.kind || payload.type || 'guidance').replace(/^guidance\./, '');
    resetMedia();
    els.card.classList.toggle('urgent', false);

    if (kind === 'clear') {
      els.kind.textContent = 'Cleared';
      els.message.textContent = '';
      pulse();
      return;
    }

    if (kind === 'image') {
      const src = payload.dataUrl || payload.url;
      els.kind.textContent = 'Reference image';
      els.message.textContent = payload.caption || 'Image from operator';
      if (src) { els.image.src = src; els.image.hidden = false; }
      pulse();
      return;
    }

    if (kind === 'location' || kind === 'location.updated') {
      const loc = payload.location || payload;
      els.kind.textContent = 'Location';
      els.message.textContent = payload.label || 'Location updated';
      els.locLabel.textContent = payload.label || 'Wearer / target';
      els.coords.textContent = formatCoords(loc.lat, loc.lng);
      els.location.hidden = false;
      showMap(loc.lat, loc.lng);   // live OpenStreetMap on the glasses HUD
      pulse();
      return;
    }

    if (kind === 'map') {
      els.kind.textContent = 'Direction';
      els.message.textContent = payload.label || 'Follow direction';
      els.arrow.style.transform = `rotate(${Number(payload.bearing || 0)}deg)`;
      els.arrow.hidden = false;
      pulse();
      return;
    }

    const text = payload.text || payload.body || payload.message || 'Operator guidance';
    els.kind.textContent = 'Operator guidance';
    els.message.textContent = text;
    els.card.classList.toggle('urgent', isUrgent(text));
    pulse();
  }

  function formatCoords(lat, lng) {
    const a = Number(lat), b = Number(lng);
    if (!Number.isFinite(a) || !Number.isFinite(b)) return 'unknown';
    return `${a.toFixed(5)}, ${b.toFixed(5)}`;
  }

  // Self-running demo: shows what the OPERATOR sends — guidance, reference
  // photos, and a live map — so you can see it on the glasses with no backend.
  function runDemo() {
    setState('demo · operator sending');
    setCase('Demo — operator guidance, photos & live map');
    const photos = [
      'https://commons.wikimedia.org/wiki/Special:FilePath/Tourniquet_CAT_training.jpg',
      'https://commons.wikimedia.org/wiki/Special:FilePath/Recovery_position.jpg',
    ];
    let lat = 50.4501, lng = 30.5234;
    const steps = [
      () => render({ kind: 'guidance', text: 'Apply firm direct pressure now' }),
      () => render({ kind: 'image', url: photos[0], caption: 'Operator: tourniquet — high & tight' }),
      () => { lat += 0.0012; lng += 0.0016; render({ kind: 'location', location: { lat, lng }, label: 'Casualty collection point' }); },
      () => render({ kind: 'guidance', text: 'Roll the casualty onto their side' }),
      () => render({ kind: 'image', url: photos[1], caption: 'Operator: recovery position' }),
      () => render({ kind: 'map', label: 'Collection point ahead', bearing: 35 }),
    ];
    let k = 0; steps[0]();
    setInterval(() => { k = (k + 1) % steps.length; steps[k](); }, 4500);
  }

  function connectBackend() {
    if (!api || !caseId) { runDemo(); return; }
    const wsBase = api.replace(/^http:/, 'ws:').replace(/^https:/, 'wss:');
    const ws = new WebSocket(`${wsBase}/api/ws`);
    setState('connecting');
    setCase(`Case ${caseId}`);
    ws.onopen = () => { setState('live'); ws.send(JSON.stringify({ type: 'subscribe_case', caseId })); };
    ws.onclose = () => { setState('offline'); setTimeout(connectBackend, 1500); };
    ws.onerror = () => setState('error');
    ws.onmessage = (event) => {
      const msg = JSON.parse(event.data);
      if (msg.type === 'case.snapshot' && msg.case?.latestLocation) render({ kind: 'location', location: msg.case.latestLocation, label: 'Current wearer location' });
      if (msg.type === 'location.updated') render({ kind: 'location', location: msg.location, label: 'Wearer moved' });
      if (msg.type === 'guidance.created') render(msg.guidance || msg.event?.payload || {});
      if (msg.type === 'case.event' && msg.event?.type?.startsWith('guidance.')) render(msg.event.payload || {});
    };
  }

  try {
    const channel = new BroadcastChannel('savevision-hud');
    channel.onmessage = (e) => render(e.data || {});
  } catch {}
  window.addEventListener('storage', (e) => {
    if (e.key === 'savevision.hud' && e.newValue) render(JSON.parse(e.newValue));
  });
  const saved = localStorage.getItem('savevision.hud');
  if (saved) { try { render(JSON.parse(saved)); } catch {} }

  connectBackend();
  window.SaveVisionHUD = { render };
})();
