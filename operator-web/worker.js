/* ============================================================================
   SaveVision — Cloudflare Worker + Durable Object port of server.js.

   Mirrors operator-web/server.js (Node) so the deployed Cloudflare app exposes
   the same backend the wearer app + console use:
     - case lifecycle (create / get / patch / claim / close / delete)
     - location (single / batch / latest / history)
     - events + guidance history, tasks
     - WebSocket: WebRTC signaling + realtime subscriptions
   Persistence: Durable Object storage (replaces data.json). Static assets via
   the [assets] binding.

   NOTE: this is a second implementation of the Node backend — keep it in sync
   with server.js when the API changes (see BACKEND_API.md).
============================================================================ */

const CASE_STATUSES = new Set(["open", "claimed", "closed", "cancelled"]);
const KYIV = [50.4501, 30.5234];
const MAX_LOC = 800, MAX_EVT = 800; // cap history so the DO value stays small

const J = (code, obj) => new Response(JSON.stringify(obj), {
  status: code,
  headers: { "content-type": "application/json", "cache-control": "no-store",
    "access-control-allow-origin": "*", "access-control-allow-methods": "GET,POST,PATCH,DELETE,OPTIONS",
    "access-control-allow-headers": "Content-Type, Authorization" },
});
const genCode = () => { const c = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"; let s = ""; for (let i = 0; i < 6; i++) s += c[Math.floor(Math.random() * c.length)]; return s; };
const makeId = (p) => `${p}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
const asNumber = (v) => { const n = Number(v); return Number.isFinite(n) ? n : undefined; };
const lifecycleFrom = (v, fb = "open") => { const s = String(v || "").toLowerCase(); return CASE_STATUSES.has(s) ? s : fb; };

function seedCases() {
  const K = KYIV;
  return [
    { id: "C-7", name: "Yusuf K.",  injury: "leg hemorrhage", sev: "crit", sector: "Sector B-4", status: "tourniquet applied", operator: "Dr. Lena", danger: "Under fire",      eta: 6,  lat: K[0] + 0.006, lng: K[1] + 0.012, createdAt: 0 },
    { id: "C-8", name: "anon-1192", injury: "unconscious",    sev: "urg",  sector: "Sector C-2", status: "airway check",        operator: "(unassigned)", danger: "Unknown",  eta: 9,  lat: K[0] - 0.009, lng: K[1] + 0.014, createdAt: 0 },
    { id: "C-9", name: "M. Haddad", injury: "burns",          sev: "urg",  sector: "Sector B-2", status: "cooling",             operator: "Dr. Adan", danger: "Hazard present", eta: 4,  lat: K[0] + 0.011, lng: K[1] - 0.010, createdAt: 0 },
    { id: "C-6", name: "anon-1187", injury: "laceration",     sev: "ok",   sector: "Sector A-3", status: "triaged",             operator: "Dr. Ivo",  danger: "Safe",           eta: 15, lat: K[0] - 0.005, lng: K[1] - 0.013, createdAt: 0 },
  ];
}
function normalizeStore(raw) {
  const now = Date.now();
  const s = raw && typeof raw === "object" ? raw : {};
  let cases = Array.isArray(s.cases) ? s.cases : [];
  const tasks = Array.isArray(s.tasks) ? s.tasks : [];
  const events = Array.isArray(s.events) ? s.events : [];
  const locations = Array.isArray(s.locations) ? s.locations : [];
  // No prescripted seed — cases come only from real backend calls (POST /api/cases).
  const used = new Set();
  for (const c of cases) {
    if (!c.id) c.id = "C-" + (Math.max(0, ...cases.map((x) => parseInt(String(x.id).split("-")[1], 10) || 0)) + 1);
    if (!c.caseStatus) c.caseStatus = c.operator && c.operator !== "(unassigned)" ? "claimed" : "open";
    c.caseStatus = lifecycleFrom(c.caseStatus);
    if (!c.status || CASE_STATUSES.has(String(c.status).toLowerCase())) c.status = c.clinicalStatus || "new";
    if (!c.operator) c.operator = "(unassigned)";
    if (!c.category) c.category = "medical";
    if (c.createdAt == null) c.createdAt = now;
    if (!c.updatedAt) c.updatedAt = c.createdAt || now;
    if (!c.roomCode) { let code = genCode(); while (used.has(code)) code = genCode(); c.roomCode = code; }
    used.add(c.roomCode);
    if (!c.latestLocation && c.lat != null && c.lng != null) {
      c.latestLocation = { id: makeId("loc"), caseId: c.id, lat: Number(c.lat), lng: Number(c.lng), accuracyM: c.accuracyM, source: "seed", ts: c.createdAt || now };
    }
  }
  return { cases, tasks, events, locations };
}
function normalizeLocation(body, caseId) {
  const input = body?.location && typeof body.location === "object" ? body.location : body || {};
  const lat = asNumber(input.lat ?? input.latitude);
  const lng = asNumber(input.lng ?? input.lon ?? input.longitude);
  if (lat === undefined || lng === undefined) return null;
  return { id: input.id || makeId("loc"), caseId, lat, lng,
    accuracyM: asNumber(input.accuracyM ?? input.accuracy ?? input.horizontalAccuracy),
    altitudeM: asNumber(input.altitudeM ?? input.altitude),
    heading: asNumber(input.heading ?? input.course),
    speedMps: asNumber(input.speedMps ?? input.speed),
    source: input.source || body?.source || "wearer",
    ts: asNumber(input.ts ?? input.timestamp) || Date.now() };
}
function summarizeCase(c) {
  return { id: c.id, caseStatus: c.caseStatus, status: c.status, category: c.category, name: c.name, injury: c.injury, sev: c.sev, operator: c.operator, roomCode: c.roomCode, matrixRoomId: c.matrixRoomId, latestLocation: c.latestLocation || null, createdAt: c.createdAt, updatedAt: c.updatedAt };
}

export class Hub {
  constructor(state, env) {
    this.state = state; this.env = env;
    this.rooms = new Map();   // roomCode -> { user, operator }
    this.sync = new Set();    // subscriber sockets (each has .caseSubs Set)
    this.ready = state.blockConcurrencyWhile(async () => {
      this.store = await state.storage.get("store");
      if (!this.store) { this.store = normalizeStore(null); await state.storage.put("store", this.store); }
      this.idSeq = Math.max(0, ...this.store.cases.map((c) => parseInt(String(c.id).split("-")[1], 10) || 0));
      this.taskSeq = Math.max(0, ...this.store.tasks.map((t) => parseInt(String(t.id).split("-")[1], 10) || 0));
    });
  }
  persist() {
    if (this.store.locations.length > MAX_LOC) this.store.locations = this.store.locations.slice(-MAX_LOC);
    if (this.store.events.length > MAX_EVT) this.store.events = this.store.events.slice(-MAX_EVT);
    return this.state.storage.put("store", this.store);
  }
  nextCaseId() { return "C-" + (++this.idSeq); }
  nextTaskId() { return "T-" + (++this.taskSeq); }
  findCase(id) { return this.store.cases.find((c) => c.id === id); }
  uniqueRoomCode() { const used = new Set(this.rooms.keys()); for (const c of this.store.cases) if (c.roomCode) used.add(c.roomCode); let code = genCode(); while (used.has(code)) code = genCode(); return code; }

  // ---- realtime fanout ----
  bcast(obj, caseId = null) { const m = JSON.stringify(obj); for (const ws of this.sync) { if (ws.readyState !== 1) continue; if (caseId && ws.caseSubs && ws.caseSubs.size > 0 && !ws.caseSubs.has(caseId)) continue; try { ws.send(m); } catch {} } }
  legacy(entity, data) { this.bcast({ type: "sync", entity, data }); }
  bcastCase(c, type = "case.updated") { this.bcast({ type, caseId: c.id, case: c }); this.legacy("case", c); }
  bcastLoc(caseId, location, c) { this.bcast({ type: "location.updated", caseId, location, case: c }, caseId); }
  bcastGuid(caseId, event, c) { this.bcast({ type: "guidance.created", caseId, event, guidance: event.payload, case: c }, caseId); }
  bcastEvent(e) { this.bcast({ type: "case.event", caseId: e.caseId, event: e }, e.caseId); }

  // ---- store ops ----
  addEvent(caseId, type, payload = {}, actor = "system", ts = Date.now()) { const e = { id: payload?.id || makeId("evt"), caseId, type, payload, actor, ts: asNumber(ts) || Date.now() }; this.store.events.push(e); return e; }
  createCase(body = {}) {
    const now = Date.now();
    const initial = normalizeLocation(body.initialLocation || body.location || body, undefined);
    const id = String(body.id || this.nextCaseId());
    const bs = String(body.status || "").toLowerCase();
    const caseStatus = body.caseStatus || body.lifecycleStatus || (CASE_STATUSES.has(bs) ? bs : "open");
    const clinical = CASE_STATUSES.has(bs) ? (body.clinicalStatus || "new") : (body.status || body.clinicalStatus || "new");
    const c = { ...body, id, caseStatus: lifecycleFrom(caseStatus), status: clinical, category: body.category || "medical",
      source: body.source || body.deviceStatus?.source || "wearer-app",
      name: body.name || body.callerName || body.patientName || `anon-${Math.floor(Math.random() * 9000) + 1000}`,
      injury: body.injury || body.summary || "unspecified emergency", sev: body.sev || body.severity || "urg",
      sector: body.sector || "unknown", operator: body.operator || "(unassigned)", danger: body.danger || body.sceneDanger || "Unknown",
      roomCode: body.roomCode || this.uniqueRoomCode(), matrixRoomId: body.matrixRoomId || null, createdAt: now, updatedAt: now };
    if (initial) { initial.caseId = id; c.lat = initial.lat; c.lng = initial.lng; c.latestLocation = initial; this.store.locations.push(initial); }
    this.store.cases.unshift(c);
    const e = this.addEvent(id, "case.created", { case: summarizeCase(c) }, body.actor || "wearer", now);
    this.persist(); this.bcastCase(c, "case.created"); this.bcastEvent(e); if (initial) this.bcastLoc(id, initial, c);
    return c;
  }
  caseSnapshot(id) { const c = this.findCase(id); if (!c) return null; const locations = this.store.locations.filter((l) => l.caseId === id).sort((a, b) => a.ts - b.ts); const events = this.store.events.filter((e) => e.caseId === id).sort((a, b) => a.ts - b.ts); return { ...c, latestLocation: c.latestLocation || locations[locations.length - 1] || null, locations, events, guidance: events.filter((e) => e.type.startsWith("guidance.")) }; }
  updateCase(id, patch = {}, actor = "operator") {
    const c = this.findCase(id); if (!c) return null;
    const bs = patch.status != null ? String(patch.status).toLowerCase() : null;
    const isLifecycle = bs && CASE_STATUSES.has(bs);
    const safe = { ...patch }; delete safe.id; delete safe.createdAt; if (isLifecycle) delete safe.status;
    Object.assign(c, safe);
    if (patch.caseStatus || patch.lifecycleStatus || isLifecycle) c.caseStatus = lifecycleFrom(patch.caseStatus || patch.lifecycleStatus || bs, c.caseStatus);
    if (patch.status != null && !isLifecycle) c.status = patch.status;
    c.updatedAt = Date.now();
    const e = this.addEvent(id, "case.updated", { patch: safe, case: summarizeCase(c) }, actor, c.updatedAt);
    this.persist(); this.bcastCase(c, "case.updated"); this.bcastEvent(e); return c;
  }
  appendLocation(id, body = {}) {
    const c = this.findCase(id); if (!c) return { error: "case not found", status: 404 };
    const loc = normalizeLocation(body, id); if (!loc) return { error: "location requires lat/lng", status: 400 };
    this.store.locations.push(loc); c.latestLocation = loc; c.lat = loc.lat; c.lng = loc.lng; c.updatedAt = Date.now();
    const e = this.addEvent(id, "location.updated", { location: loc }, body.actor || "wearer", loc.ts);
    this.persist(); this.bcastLoc(id, loc, c); this.bcastEvent(e); this.legacy("case", c);
    return { location: loc, event: e, case: c };
  }
  appendGuidance(id, payload = {}) {
    const c = this.findCase(id); if (!c) return { error: "case not found", status: 404 };
    const kind = String(payload.kind || "guidance");
    if (!new Set(["guidance", "drawing", "clear", "image", "map"]).has(kind)) return { error: "unsupported guidance kind", status: 400 };
    const body = { ...payload, kind, ts: asNumber(payload.ts) || Date.now() };
    const e = this.addEvent(id, `guidance.${kind}`, body, payload.actor || "operator", body.ts);
    c.updatedAt = Date.now(); this.persist(); this.bcastGuid(id, e, c); this.bcastEvent(e); return { event: e };
  }

  async fetch(request) {
    await this.ready;
    if ((request.headers.get("Upgrade") || "").toLowerCase() === "websocket") {
      const pair = new WebSocketPair(); pair[1].accept(); this.attach(pair[1]);
      return new Response(null, { status: 101, webSocket: pair[0] });
    }
    return this.api(request);
  }

  async api(request) {
    const url = new URL(request.url); const p = decodeURIComponent(url.pathname); const m = request.method;
    const ICE = () => {                       // #1: TURN-capable ICE (cross-network)
      const list = [{ urls: "stun:stun.l.google.com:19302" }];
      const e = this.env || {};
      if (e.TURN_URL && e.TURN_USER && e.TURN_PASS) list.push({ urls: String(e.TURN_URL).split(","), username: e.TURN_USER, credential: e.TURN_PASS });
      return { iceServers: list };
    };
    if (m === "OPTIONS") return new Response(null, { status: 204, headers: { "access-control-allow-origin": "*", "access-control-allow-methods": "GET,POST,PATCH,DELETE,OPTIONS", "access-control-allow-headers": "Content-Type, Authorization" } });
    const body = async () => { try { return await request.json(); } catch { return {}; } };
    const lim = (fb, mx) => { const n = Number(url.searchParams.get("limit") || fb); return !Number.isFinite(n) || n <= 0 ? fb : Math.min(n, mx); };

    if (p === "/api/health" && m === "GET") return J(200, { ok: true, cases: this.store.cases.length, events: this.store.events.length, locations: this.store.locations.length });
    if (p === "/api/ice" && m === "GET") return J(200, ICE());

    if (p === "/api/cases" && m === "GET") {
      let cs = [...this.store.cases]; const st = url.searchParams.get("status"); const op = url.searchParams.get("operator");
      if (st) cs = cs.filter((c) => c.caseStatus === st || c.status === st);
      if (op) cs = cs.filter((c) => c.operator === op || c.operatorId === op);
      cs.sort((a, b) => (b.updatedAt || b.createdAt || 0) - (a.updatedAt || a.createdAt || 0));
      return J(200, cs.slice(0, lim(200, 2000)));
    }
    if (p === "/api/cases" && m === "POST") { const c = this.createCase(await body()); return J(201, { ...c, iceServers: ICE().iceServers }); }

    const cm = p.match(/^\/api\/cases\/([^/]+)(?:\/(.*))?$/);
    if (cm) {
      const id = decodeURIComponent(cm[1]); const sub = cm[2] || ""; const c = this.findCase(id);
      if (!c) return J(404, { error: "case not found" });
      if (!sub && m === "GET") return J(200, this.caseSnapshot(id));
      if (!sub && m === "PATCH") { const b = await body(); return J(200, this.updateCase(id, b, b.actor || "operator")); }
      if (!sub && m === "DELETE") { this.store.cases = this.store.cases.filter((x) => x.id !== id); this.store.locations = this.store.locations.filter((x) => x.caseId !== id); this.store.events = this.store.events.filter((x) => x.caseId !== id); this.persist(); this.bcast({ type: "case.deleted", caseId: id }); this.legacy("case_removed", { id }); return J(200, { ok: true }); }
      if (sub === "claim" && m === "POST") { const b = await body(); const op = b.operator || b.operatorName || b.name || "operator"; return J(200, this.updateCase(id, { caseStatus: "claimed", operator: op, operatorId: b.operatorId || b.userId, claimedAt: Date.now() }, op)); }
      if (sub === "close" && m === "POST") { const b = await body(); return J(200, this.updateCase(id, { caseStatus: "closed", closeReason: b.reason || b.closeReason || "closed", closedAt: Date.now() }, b.actor || "operator")); }
      if (sub === "location" && m === "POST") { const r = this.appendLocation(id, await body()); return r.error ? J(r.status, { error: r.error }) : J(201, r.location); }
      if (sub === "location/batch" && m === "POST") { const b = await body(); const list = Array.isArray(b.locations) ? b.locations : []; if (!list.length) return J(400, { error: "locations[] required" }); const added = []; for (const it of list) { const r = this.appendLocation(id, { ...it, actor: b.actor }); if (!r.error) added.push(r.location); } return J(201, { locations: added }); }
      if (sub === "location/latest" && m === "GET") { const locs = this.store.locations.filter((l) => l.caseId === id).sort((a, b) => a.ts - b.ts); return J(200, c.latestLocation || locs[locs.length - 1] || null); }
      if (sub === "location/history" && m === "GET") { const since = Number(url.searchParams.get("since") || 0); const locs = this.store.locations.filter((l) => l.caseId === id && (!since || l.ts > since)).sort((a, b) => a.ts - b.ts).slice(-lim(500, 5000)); return J(200, locs); }
      if (sub === "events" && m === "GET") { const after = url.searchParams.get("after"); const an = Number(after || 0); let ev = this.store.events.filter((e) => e.caseId === id); if (after) ev = ev.filter((e) => (Number.isFinite(an) && an > 0) ? e.ts > an : e.id > after); ev.sort((a, b) => a.ts - b.ts); return J(200, ev.slice(-lim(200, 2000))); }
      if (sub === "events" && m === "POST") { const b = await body(); if (!b.type) return J(400, { error: "event type required" }); const e = this.addEvent(id, b.type, b.payload || b, b.actor || "app", b.ts || Date.now()); c.updatedAt = Date.now(); this.persist(); this.bcastEvent(e); return J(201, e); }
      if (sub === "guidance" && m === "GET") { const ev = this.store.events.filter((e) => e.caseId === id && e.type.startsWith("guidance.")).sort((a, b) => a.ts - b.ts); return J(200, ev.slice(-lim(100, 1000))); }
      if (sub === "guidance" && m === "POST") { const r = this.appendGuidance(id, await body()); return r.error ? J(r.status, { error: r.error }) : J(201, r.event); }
    }

    if (p === "/api/tasks" && m === "GET") { let ts = [...this.store.tasks]; const cid = url.searchParams.get("caseId"); if (cid) ts = ts.filter((t) => t.caseId === cid); return J(200, ts.slice(0, lim(200, 2000))); }
    if (p === "/api/tasks" && m === "POST") { const b = await body(); const t = { id: b.id || this.nextTaskId(), status: "todo", ...b, createdAt: Date.now(), updatedAt: Date.now() }; this.store.tasks.unshift(t); if (t.caseId) this.addEvent(t.caseId, "task.created", { task: t }, b.actor || "operator"); this.persist(); this.bcast({ type: "task.created", task: t, caseId: t.caseId }); this.legacy("task", t); return J(201, t); }
    const tm = p.match(/^\/api\/tasks\/([^/]+)$/);
    if (tm && m === "PATCH") { const b = await body(); const t = this.store.tasks.find((x) => x.id === decodeURIComponent(tm[1])); if (!t) return J(404, { error: "task not found" }); Object.assign(t, b, { updatedAt: Date.now() }); if (t.caseId) this.addEvent(t.caseId, "task.updated", { task: t }, b.actor || "operator"); this.persist(); this.bcast({ type: "task.updated", task: t, caseId: t.caseId }); this.legacy("task", t); return J(200, t); }

    if (p === "/api/guidance" && m === "POST") {
      const b = await body();
      const key = (this.env || {}).ANTHROPIC_API_KEY;
      // No key (or no frame) → free sample, $0. With a key → PAID Claude vision call.
      if (!key || !b.frame) {
        return J(200, { proposal: { assessment: "Sample assessment (no AI key set).", march: [{ step: "M", action: "Control massive bleeding — firm direct pressure / tourniquet high & tight." }], banner: "Apply firm direct pressure now", steps: ["Apply firm direct pressure", "If a limb bleed won't stop, tourniquet high & tight"] }, note: "stand-in (set ANTHROPIC_API_KEY for real per-injury guidance)" });
      }
      try {
        const mt = (String(b.frame).match(/^data:(image\/\w+);base64,/) || [])[1] || "image/jpeg";
        const data = String(b.frame).split(",")[1] || "";
        const model = this.env.ANTHROPIC_MODEL || "claude-haiku-4-5-20251001";
        const sys = "You are a TCCC-trained emergency physician guiding an UNTRAINED bystander wearing smart glasses in a war/emergency zone. From the first-person photo (and optional hint), assess and direct the SAFEST next lay actions only (no invasive procedures). Reply with ONLY a JSON object: {\"assessment\":string, \"march\":[{\"step\":\"M|A|R|C|H\",\"action\":string}], \"banner\":string (ONE short imperative for the glasses display), \"steps\":[string]}. MARCH = Massive hemorrhage, Airway, Respiration, Circulation, Head/Hypothermia. If the image is unclear, say so in assessment and give the safest next step.";
        const r = await fetch("https://api.anthropic.com/v1/messages", {
          method: "POST",
          headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
          body: JSON.stringify({ model, max_tokens: 800, system: sys, messages: [{ role: "user", content: [{ type: "image", source: { type: "base64", media_type: mt, data } }, { type: "text", text: "Hint from operator: " + (b.hint || "none") + ". Return only the JSON object." }] }] }),
        });
        const j = await r.json();
        if (!r.ok) return J(200, { error: (j.error && j.error.message) || ("AI HTTP " + r.status), proposal: { banner: "(AI unavailable — guide manually)" } });
        const txt = (j.content || []).filter((c) => c.type === "text").map((c) => c.text).join("");
        let parsed; try { parsed = JSON.parse(txt.slice(txt.indexOf("{"), txt.lastIndexOf("}") + 1)); } catch { parsed = { assessment: txt, march: [], banner: "", steps: [] }; }
        return J(200, { proposal: parsed, model, usage: j.usage || null });
      } catch (e) { return J(200, { error: String(e), proposal: { banner: "(AI error — guide manually)" } }); }
    }
    return J(404, { error: "unknown endpoint" });
  }

  attach(ws) {
    let room = null, role = null;
    ws.caseSubs = new Set();
    const send = (t, o) => { try { if (t && t.readyState === 1) t.send(JSON.stringify(o)); } catch {} };
    ws.addEventListener("message", (ev) => {
      let msg; try { msg = JSON.parse(ev.data); } catch { return; }
      switch (msg.type) {
        case "create": { const lc = msg.caseId ? this.findCase(String(msg.caseId)) : null; const preferred = lc?.roomCode && !this.rooms.has(lc.roomCode) ? lc.roomCode : null; const code = preferred || this.uniqueRoomCode(); this.rooms.set(code, { user: ws, operator: null }); room = code; role = "user"; if (lc) { lc.roomCode = code; lc.updatedAt = Date.now(); this.persist(); this.bcastCase(lc, "case.updated"); } send(ws, { type: "room_created", room: code, ...(lc ? { caseId: lc.id } : {}) }); break; }
        case "rejoin": { const r = this.rooms.get(msg.room); if (!r) return send(ws, { type: "error", message: "Room not found" }); r.user = ws; room = msg.room; role = "user"; send(ws, { type: "room_rejoined", room: msg.room }); if (r.operator && r.operator.readyState === 1) send(ws, { type: "peer_joined" }); break; }
        case "join": { const r = this.rooms.get(msg.room); if (!r) return send(ws, { type: "error", message: "Room not found" }); if (r.operator && r.operator.readyState === 1) return send(ws, { type: "error", message: "Room is full" }); r.operator = ws; room = msg.room; role = "operator"; send(ws, { type: "room_joined" }); send(r.user, { type: "peer_joined" }); break; }
        case "offer": case "answer": case "candidate": { const r = this.rooms.get(room); if (!r) return; send(role === "user" ? r.operator : r.user, msg); break; }
        case "subscribe_sync": { this.sync.add(ws); send(ws, { type: "sync_snapshot", cases: this.store.cases, tasks: this.store.tasks }); break; }
        case "subscribe_cases": { this.sync.add(ws); send(ws, { type: "cases.snapshot", cases: this.store.cases }); break; }
        case "subscribe_case": { this.sync.add(ws); if (msg.caseId) ws.caseSubs.add(String(msg.caseId)); const snap = msg.caseId ? this.caseSnapshot(String(msg.caseId)) : null; snap ? send(ws, { type: "case.snapshot", caseId: snap.id, case: snap }) : send(ws, { type: "error", message: "case not found" }); break; }
        case "unsubscribe_case": { if (msg.caseId) ws.caseSubs.delete(String(msg.caseId)); break; }
        case "ping": { send(ws, { type: "pong", ts: Date.now() }); break; }
      }
    });
    ws.addEventListener("close", () => {
      this.sync.delete(ws);
      if (room && this.rooms.has(room)) { const r = this.rooms.get(room); send(role === "user" ? r.operator : r.user, { type: "peer_left" }); if (role === "user") r.user = null; else r.operator = null; }
    });
  }
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const isWS = (request.headers.get("Upgrade") || "").toLowerCase() === "websocket";
    if (isWS || url.pathname.startsWith("/api/")) {
      return env.HUB.get(env.HUB.idFromName("global")).fetch(request);
    }
    if (url.pathname === "/" || url.pathname === "") {
      return env.ASSETS.fetch(new Request(new URL("/index.html", request.url), request));
    }
    return env.ASSETS.fetch(request);
  },
};
