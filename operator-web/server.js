/* ============================================================================
   SaveVision — operator-web server

   Responsibilities:
   - Serves the operator dashboard (public/).
   - Provides the case backend API used by the wearer app and operator console.
   - Pushes real-time case/location/guidance updates over WebSocket.
   - Relays local-dev WebRTC signaling between a "user" (wearer) and an
     "operator" that share a 6-char room code.
   - Hands out ICE servers via /api/ice (STUN by default; set TURN_* env vars to
     add a relay for restrictive networks).

   Production transport still targets Matrix (see ../MATRIX.md). This backend is
   the deployable app/API seam: it keeps case state, live location, operator
   assignment, and guidance history available across reconnects.
============================================================================ */

const http = require("http");
const fs = require("fs");
const path = require("path");
const { WebSocketServer } = require("ws");

const PORT = process.env.PORT || 8080;
const DATA_FILE = process.env.SAVEVISION_DATA_FILE || path.join(__dirname, "data.json");
const MAX_BODY_BYTES = Number(process.env.MAX_BODY_BYTES || 10 * 1024 * 1024);
const CASE_STATUSES = new Set(["open", "claimed", "closed", "cancelled"]);

// roomCode -> { user: ws|null, operator: ws|null, destroyTimer: timeout|null }
const rooms = new Map();

// Grace period before destroying a room when the user (publisher) drops — lets
// the glasses wearer background the app (share the code, take a call) and return.
const ROOM_GRACE_PERIOD_MS = 60_000;

const MIME = {
  ".html": "text/html",
  ".js": "application/javascript",
  ".css": "text/css",
  ".svg": "image/svg+xml",
  ".json": "application/json",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
};

// ICE configuration. STUN is enough on most networks. For locked-down mobile
// networks, provide a TURN relay via env vars (never hard-code credentials).
function getIceServers() {
  const iceServers = [{ urls: "stun:stun.l.google.com:19302" }];
  if (process.env.TURN_URL && process.env.TURN_USER && process.env.TURN_PASS) {
    iceServers.push({
      urls: process.env.TURN_URL.split(","),
      username: process.env.TURN_USER,
      credential: process.env.TURN_PASS,
    });
  }
  return { iceServers };
}

function generateRoomCode() {
  // Unambiguous alphabet (no 0/O, 1/I/L).
  const chars = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
  let code = "";
  for (let i = 0; i < 6; i++) code += chars[Math.floor(Math.random() * chars.length)];
  return code;
}

function uniqueRoomCode(extraUsed = new Set()) {
  const used = new Set(extraUsed);
  for (const c of store?.cases || []) if (c.roomCode) used.add(c.roomCode);
  for (const c of rooms.keys()) used.add(c);
  let code = generateRoomCode();
  while (used.has(code)) code = generateRoomCode();
  return code;
}

function send(ws, obj) {
  if (ws && ws.readyState === 1) ws.send(JSON.stringify(obj));
}

function makeId(prefix) {
  return `${prefix}-${Date.now().toString(36)}-${Math.random().toString(36).slice(2, 8)}`;
}

function asNumber(value) {
  const n = Number(value);
  return Number.isFinite(n) ? n : undefined;
}

function lifecycleFrom(value, fallback = "open") {
  const s = String(value || "").toLowerCase();
  return CASE_STATUSES.has(s) ? s : fallback;
}

/* ============================================================================
   Backend store — cases, locations, events, and tasks.
   This uses a local JSON file so the prototype is deployable with no database.
   Swap the functions in this block for Postgres/Redis later without changing
   the REST/WebSocket contract.
============================================================================ */
let saveTimer = null;
let store = loadStore();
let idSeq = Math.max(0, ...store.cases.map((c) => parseInt(String(c.id).split("-")[1], 10) || 0));
let taskSeq = Math.max(0, ...store.tasks.map((t) => parseInt(String(t.id).split("-")[1], 10) || 0));

function nextCaseId() { return "C-" + (++idSeq); }
function nextTaskId() { return "T-" + (++taskSeq); }

function loadStore() {
  let raw = null;
  try { raw = JSON.parse(fs.readFileSync(DATA_FILE, "utf8")); } catch {}
  const normalized = normalizeStore(raw);
  if (normalized._changed) persistSoon(normalized);
  delete normalized._changed;
  return normalized;
}

function normalizeStore(raw) {
  const now = Date.now();
  const s = raw && typeof raw === "object" ? raw : {};
  const changed = { value: !raw };
  const usedRoomCodes = new Set();
  const cases = Array.isArray(s.cases) ? s.cases : [];
  const tasks = Array.isArray(s.tasks) ? s.tasks : [];
  const events = Array.isArray(s.events) ? s.events : [];
  const locations = Array.isArray(s.locations) ? s.locations : [];

  // No prescripted seed — cases come only from real backend calls (POST /api/cases).

  for (const c of cases) {
    if (!c.id) { c.id = nextGeneratedCaseId(cases); changed.value = true; }
    if (!c.caseStatus) { c.caseStatus = c.operator && c.operator !== "(unassigned)" ? "claimed" : "open"; changed.value = true; }
    c.caseStatus = lifecycleFrom(c.caseStatus);
    if (!c.status || CASE_STATUSES.has(String(c.status).toLowerCase())) { c.status = c.clinicalStatus || "new"; changed.value = true; }
    if (!c.operator) { c.operator = "(unassigned)"; changed.value = true; }
    if (!c.category) { c.category = "medical"; changed.value = true; }
    if (!c.createdAt && c.createdAt !== 0) { c.createdAt = now; changed.value = true; }
    if (!c.updatedAt) { c.updatedAt = c.createdAt || now; changed.value = true; }
    if (!c.roomCode) { c.roomCode = uniqueRoomCodeForMigration(usedRoomCodes); changed.value = true; }
    usedRoomCodes.add(c.roomCode);
    if (!c.latestLocation && c.lat != null && c.lng != null) {
      c.latestLocation = {
        id: makeId("loc"), caseId: c.id,
        lat: Number(c.lat), lng: Number(c.lng),
        accuracyM: c.accuracyM, source: "seed", ts: c.createdAt || now,
      };
      changed.value = true;
    }
  }

  return { cases, tasks, events, locations, _changed: changed.value };
}

function nextGeneratedCaseId(cases) {
  const max = Math.max(0, ...cases.map((c) => parseInt(String(c.id).split("-")[1], 10) || 0));
  return "C-" + (max + 1);
}

function uniqueRoomCodeForMigration(used) {
  let code = generateRoomCode();
  while (used.has(code)) code = generateRoomCode();
  used.add(code);
  return code;
}

function seedCases(cases) {
  // Seed Kyiv cases on first run so the console has real backend data (not mocked).
  const K = [50.4501, 30.5234];
  const seeded = [
    { id: "C-7", name: "Yusuf K.",  injury: "leg hemorrhage", sev: "crit", sector: "Sector B-4", status: "tourniquet applied", operator: "Dr. Lena", danger: "Under fire",      eta: 6,  lat: K[0] + 0.006, lng: K[1] + 0.012, createdAt: 0 },
    { id: "C-8", name: "anon-1192", injury: "unconscious",    sev: "urg",  sector: "Sector C-2", status: "airway check",        operator: "(unassigned)", danger: "Unknown",  eta: 9,  lat: K[0] - 0.009, lng: K[1] + 0.014, createdAt: 0 },
    { id: "C-9", name: "M. Haddad", injury: "burns",          sev: "urg",  sector: "Sector B-2", status: "cooling",             operator: "Dr. Adan", danger: "Hazard present", eta: 4,  lat: K[0] + 0.011, lng: K[1] - 0.010, createdAt: 0 },
    { id: "C-6", name: "anon-1187", injury: "laceration",     sev: "ok",   sector: "Sector A-3", status: "triaged",             operator: "Dr. Ivo",  danger: "Safe",           eta: 15, lat: K[0] - 0.005, lng: K[1] - 0.013, createdAt: 0 },
  ];
  cases.push(...seeded);
}

function persistSoon(nextStore = store) {
  clearTimeout(saveTimer);
  saveTimer = setTimeout(() => {
    fs.writeFile(DATA_FILE, JSON.stringify(nextStore, null, 2), (e) => {
      if (e) console.log("persist error:", e.message);
    });
  }, 150);
}

function findCase(caseId) {
  return store.cases.find((c) => c.id === caseId);
}

function normalizeLocation(body, caseId) {
  const input = body?.location && typeof body.location === "object" ? body.location : body || {};
  const lat = asNumber(input.lat ?? input.latitude);
  const lng = asNumber(input.lng ?? input.lon ?? input.longitude);
  if (lat === undefined || lng === undefined) return null;
  return {
    id: input.id || makeId("loc"),
    caseId,
    lat,
    lng,
    accuracyM: asNumber(input.accuracyM ?? input.accuracy ?? input.horizontalAccuracy),
    altitudeM: asNumber(input.altitudeM ?? input.altitude),
    heading: asNumber(input.heading ?? input.course),
    speedMps: asNumber(input.speedMps ?? input.speed),
    source: input.source || body?.source || "wearer",
    ts: asNumber(input.ts ?? input.timestamp) || Date.now(),
  };
}

function addEvent(caseId, type, payload = {}, actor = "system", ts = Date.now()) {
  const event = {
    id: payload?.id || makeId("evt"),
    caseId,
    type,
    payload,
    actor,
    ts: asNumber(ts) || Date.now(),
  };
  store.events.push(event);
  return event;
}

function createCase(body = {}) {
  const now = Date.now();
  const initialLocation = normalizeLocation(body.initialLocation || body.location || body, undefined);
  const id = String(body.id || nextCaseId());
  const bodyStatus = String(body.status || "").toLowerCase();
  const caseStatus = body.caseStatus || body.lifecycleStatus || (CASE_STATUSES.has(bodyStatus) ? bodyStatus : "open");
  const clinicalStatus = CASE_STATUSES.has(bodyStatus) ? (body.clinicalStatus || "new") : (body.status || body.clinicalStatus || "new");

  const c = {
    ...body,
    id,
    caseStatus: lifecycleFrom(caseStatus),
    status: clinicalStatus,
    category: body.category || "medical",
    source: body.source || body.deviceStatus?.source || "wearer-app",
    name: body.name || body.callerName || body.patientName || `anon-${String(Math.floor(Math.random() * 9000) + 1000)}`,
    injury: body.injury || body.summary || "unspecified emergency",
    sev: body.sev || body.severity || "urg",
    sector: body.sector || "unknown",
    operator: body.operator || "(unassigned)",
    danger: body.danger || body.sceneDanger || "Unknown",
    roomCode: body.roomCode || uniqueRoomCode(),
    matrixRoomId: body.matrixRoomId || null,
    createdAt: now,
    updatedAt: now,
  };

  if (initialLocation) {
    initialLocation.caseId = id;
    c.lat = initialLocation.lat;
    c.lng = initialLocation.lng;
    c.latestLocation = initialLocation;
    store.locations.push(initialLocation);
  }

  store.cases.unshift(c);
  const event = addEvent(id, "case.created", { case: summarizeCase(c) }, body.actor || "wearer", now);
  persistSoon();
  broadcastCase(c, "case.created");
  broadcastEvent(event);
  if (initialLocation) broadcastLocation(id, initialLocation, c);
  return c;
}

function summarizeCase(c) {
  return {
    id: c.id,
    caseStatus: c.caseStatus,
    status: c.status,
    category: c.category,
    name: c.name,
    injury: c.injury,
    sev: c.sev,
    operator: c.operator,
    roomCode: c.roomCode,
    matrixRoomId: c.matrixRoomId,
    latestLocation: c.latestLocation || null,
    createdAt: c.createdAt,
    updatedAt: c.updatedAt,
  };
}

function caseSnapshot(caseId) {
  const c = findCase(caseId);
  if (!c) return null;
  const locations = store.locations.filter((l) => l.caseId === caseId).sort((a, b) => a.ts - b.ts);
  const events = store.events.filter((e) => e.caseId === caseId).sort((a, b) => a.ts - b.ts);
  return {
    ...c,
    latestLocation: c.latestLocation || locations[locations.length - 1] || null,
    locations,
    events,
    guidance: events.filter((e) => e.type.startsWith("guidance.")),
  };
}

function updateCase(caseId, patch = {}, actor = "operator") {
  const c = findCase(caseId);
  if (!c) return null;
  const bodyStatus = patch.status != null ? String(patch.status).toLowerCase() : null;
  const statusIsLifecycle = bodyStatus && CASE_STATUSES.has(bodyStatus);
  const safePatch = { ...patch };
  delete safePatch.id;
  delete safePatch.createdAt;
  if (statusIsLifecycle) delete safePatch.status;

  Object.assign(c, safePatch);
  if (patch.caseStatus || patch.lifecycleStatus || statusIsLifecycle) {
    c.caseStatus = lifecycleFrom(patch.caseStatus || patch.lifecycleStatus || bodyStatus, c.caseStatus);
  }
  if (patch.status != null && !statusIsLifecycle) c.status = patch.status;
  c.updatedAt = Date.now();

  const event = addEvent(caseId, "case.updated", { patch: safePatch, case: summarizeCase(c) }, actor, c.updatedAt);
  persistSoon();
  broadcastCase(c, "case.updated");
  broadcastEvent(event);
  return c;
}

function appendLocation(caseId, body = {}) {
  const c = findCase(caseId);
  if (!c) return { error: "case not found", status: 404 };
  const loc = normalizeLocation(body, caseId);
  if (!loc) return { error: "location requires lat/lng", status: 400 };

  store.locations.push(loc);
  c.latestLocation = loc;
  c.lat = loc.lat;
  c.lng = loc.lng;
  c.updatedAt = Date.now();
  const event = addEvent(caseId, "location.updated", { location: loc }, body.actor || "wearer", loc.ts);
  persistSoon();
  broadcastLocation(caseId, loc, c);
  broadcastEvent(event);
  // Keep legacy operator consoles in sync even if they only understand case sync.
  broadcastLegacy("case", c);
  return { location: loc, event, case: c };
}

function appendGuidance(caseId, payload = {}) {
  const c = findCase(caseId);
  if (!c) return { error: "case not found", status: 404 };
  const kind = String(payload.kind || "guidance");
  const allowed = new Set(["guidance", "drawing", "clear", "image", "map"]);
  if (!allowed.has(kind)) return { error: "unsupported guidance kind", status: 400 };

  const body = { ...payload, kind, ts: asNumber(payload.ts) || Date.now() };
  const event = addEvent(caseId, `guidance.${kind}`, body, payload.actor || "operator", body.ts);
  c.updatedAt = Date.now();
  persistSoon();
  broadcastGuidance(caseId, event, c);
  broadcastEvent(event);
  return { event };
}

/* ============================================================================
   Real-time API fanout.

   New clients should connect to ws(s)://host/api/ws and send:
   {"type":"subscribe_cases"} or {"type":"subscribe_case","caseId":"C-10"}

   Existing console.html still uses {"type":"subscribe_sync"}; keep that legacy
   shape so old screens continue to update.
============================================================================ */
const syncClients = new Set();

function broadcastToSubscribers(obj, caseId = null) {
  for (const client of syncClients) {
    if (client.readyState !== 1) continue;
    const subs = client.caseSubscriptions;
    if (caseId && subs && subs.size > 0 && !subs.has(caseId)) continue;
    send(client, obj);
  }
}

function broadcastLegacy(entity, data) {
  broadcastToSubscribers({ type: "sync", entity, data });
}

function broadcastCase(c, type = "case.updated") {
  broadcastToSubscribers({ type, caseId: c.id, case: c });
  broadcastLegacy("case", c);
}

function broadcastLocation(caseId, location, c) {
  broadcastToSubscribers({ type: "location.updated", caseId, location, case: c }, caseId);
}

function broadcastGuidance(caseId, event, c) {
  broadcastToSubscribers({ type: "guidance.created", caseId, event, guidance: event.payload, case: c }, caseId);
}

function broadcastEvent(event) {
  broadcastToSubscribers({ type: "case.event", caseId: event.caseId, event }, event.caseId);
}

/* ============================================================================
   HTTP API
============================================================================ */
function setCors(res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET,POST,PATCH,DELETE,OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");
}

function sendJSON(res, code, obj) {
  setCors(res);
  res.writeHead(code, { "Content-Type": "application/json", "Cache-Control": "no-store" });
  res.end(JSON.stringify(obj));
}

function sendError(res, code, message, details) {
  sendJSON(res, code, { error: message, ...(details ? { details } : {}) });
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    let body = "";
    req.on("data", (chunk) => {
      body += chunk;
      if (Buffer.byteLength(body) > MAX_BODY_BYTES) {
        const err = new Error("request body too large");
        err.status = 413;
        reject(err);
        req.destroy();
      }
    });
    req.on("end", () => {
      if (!body) return resolve({});
      try { resolve(JSON.parse(body)); }
      catch {
        const err = new Error("invalid JSON body");
        err.status = 400;
        reject(err);
      }
    });
    req.on("error", reject);
  });
}

function parseLimit(url, fallback = 200, max = 2000) {
  const n = Number(url.searchParams.get("limit") || fallback);
  if (!Number.isFinite(n) || n <= 0) return fallback;
  return Math.min(n, max);
}

async function handleApi(req, res, url) {
  const pathname = decodeURIComponent(url.pathname);
  if (req.method === "OPTIONS") { setCors(res); res.writeHead(204); return res.end(); }

  if (pathname === "/api/health" && req.method === "GET") {
    return sendJSON(res, 200, { ok: true, cases: store.cases.length, events: store.events.length, locations: store.locations.length });
  }

  if (pathname === "/api/ice" && req.method === "GET") return sendJSON(res, 200, getIceServers());

  if (pathname === "/api/cases" && req.method === "GET") {
    let cases = [...store.cases];
    const status = url.searchParams.get("status");
    const operator = url.searchParams.get("operator");
    if (status) cases = cases.filter((c) => c.caseStatus === status || c.status === status);
    if (operator) cases = cases.filter((c) => c.operator === operator || c.operatorId === operator);
    cases.sort((a, b) => (b.updatedAt || b.createdAt || 0) - (a.updatedAt || a.createdAt || 0));
    return sendJSON(res, 200, cases.slice(0, parseLimit(url, 200)));
  }

  if (pathname === "/api/cases" && req.method === "POST") {
    const body = await readBody(req);
    const c = createCase(body);
    return sendJSON(res, 201, { ...c, iceServers: getIceServers().iceServers });
  }

  const caseMatch = pathname.match(/^\/api\/cases\/([^/]+)(?:\/(.*))?$/);
  if (caseMatch) {
    const caseId = decodeURIComponent(caseMatch[1]);
    const subpath = caseMatch[2] || "";
    const c = findCase(caseId);
    if (!c && req.method !== "OPTIONS") return sendError(res, 404, "case not found");

    if (!subpath && req.method === "GET") return sendJSON(res, 200, caseSnapshot(caseId));

    if (!subpath && req.method === "PATCH") {
      const body = await readBody(req);
      const updated = updateCase(caseId, body, body.actor || "operator");
      return sendJSON(res, 200, updated);
    }

    if (!subpath && req.method === "DELETE") {
      store.cases = store.cases.filter((x) => x.id !== caseId);
      store.locations = store.locations.filter((x) => x.caseId !== caseId);
      store.events = store.events.filter((x) => x.caseId !== caseId);
      persistSoon();
      broadcastToSubscribers({ type: "case.deleted", caseId });
      broadcastLegacy("case_removed", { id: caseId });
      return sendJSON(res, 200, { ok: true });
    }

    if (subpath === "claim" && req.method === "POST") {
      const body = await readBody(req);
      const operator = body.operator || body.operatorName || body.name || "operator";
      const updated = updateCase(caseId, {
        caseStatus: "claimed",
        operator,
        operatorId: body.operatorId || body.userId,
        claimedAt: Date.now(),
      }, operator);
      return sendJSON(res, 200, updated);
    }

    if (subpath === "close" && req.method === "POST") {
      const body = await readBody(req);
      const updated = updateCase(caseId, {
        caseStatus: "closed",
        closeReason: body.reason || body.closeReason || "closed",
        closedAt: Date.now(),
      }, body.actor || "operator");
      return sendJSON(res, 200, updated);
    }

    if (subpath === "location" && req.method === "POST") {
      const body = await readBody(req);
      const result = appendLocation(caseId, body);
      if (result.error) return sendError(res, result.status, result.error);
      return sendJSON(res, 201, result.location);
    }

    if (subpath === "location/batch" && req.method === "POST") {
      const body = await readBody(req);
      const list = Array.isArray(body.locations) ? body.locations : [];
      if (list.length === 0) return sendError(res, 400, "locations[] required");
      const added = [];
      for (const item of list) {
        const result = appendLocation(caseId, { ...item, actor: body.actor });
        if (!result.error) added.push(result.location);
      }
      return sendJSON(res, 201, { locations: added });
    }

    if (subpath === "location/latest" && req.method === "GET") {
      const locations = store.locations.filter((l) => l.caseId === caseId).sort((a, b) => a.ts - b.ts);
      return sendJSON(res, 200, c.latestLocation || locations[locations.length - 1] || null);
    }

    if (subpath === "location/history" && req.method === "GET") {
      const since = Number(url.searchParams.get("since") || 0);
      const limit = parseLimit(url, 500, 5000);
      const locations = store.locations
        .filter((l) => l.caseId === caseId && (!since || l.ts > since))
        .sort((a, b) => a.ts - b.ts)
        .slice(-limit);
      return sendJSON(res, 200, locations);
    }

    if (subpath === "events" && req.method === "GET") {
      const after = url.searchParams.get("after");
      const afterN = Number(after || 0);
      const limit = parseLimit(url, 200, 2000);
      let events = store.events.filter((e) => e.caseId === caseId);
      if (after) events = events.filter((e) => (Number.isFinite(afterN) && afterN > 0) ? e.ts > afterN : e.id > after);
      events.sort((a, b) => a.ts - b.ts);
      return sendJSON(res, 200, events.slice(-limit));
    }

    if (subpath === "events" && req.method === "POST") {
      const body = await readBody(req);
      if (!body.type) return sendError(res, 400, "event type required");
      const event = addEvent(caseId, body.type, body.payload || body, body.actor || "app", body.ts || Date.now());
      c.updatedAt = Date.now();
      persistSoon();
      broadcastEvent(event);
      return sendJSON(res, 201, event);
    }

    if (subpath === "guidance" && req.method === "GET") {
      const events = store.events.filter((e) => e.caseId === caseId && e.type.startsWith("guidance.")).sort((a, b) => a.ts - b.ts);
      return sendJSON(res, 200, events.slice(-parseLimit(url, 100, 1000)));
    }

    if (subpath === "guidance" && req.method === "POST") {
      const body = await readBody(req);
      const result = appendGuidance(caseId, body);
      if (result.error) return sendError(res, result.status, result.error);
      return sendJSON(res, 201, result.event);
    }
  }

  if (pathname === "/api/tasks" && req.method === "GET") {
    let tasks = [...store.tasks];
    const caseId = url.searchParams.get("caseId");
    if (caseId) tasks = tasks.filter((t) => t.caseId === caseId);
    return sendJSON(res, 200, tasks.slice(0, parseLimit(url, 200)));
  }

  if (pathname === "/api/tasks" && req.method === "POST") {
    const body = await readBody(req);
    const t = { id: body.id || nextTaskId(), status: "todo", ...body, createdAt: Date.now(), updatedAt: Date.now() };
    store.tasks.unshift(t);
    if (t.caseId) addEvent(t.caseId, "task.created", { task: t }, body.actor || "operator");
    persistSoon();
    broadcastToSubscribers({ type: "task.created", task: t, caseId: t.caseId });
    broadcastLegacy("task", t);
    return sendJSON(res, 201, t);
  }

  const taskMatch = pathname.match(/^\/api\/tasks\/([^/]+)$/);
  if (taskMatch && req.method === "PATCH") {
    const body = await readBody(req);
    const t = store.tasks.find((x) => x.id === decodeURIComponent(taskMatch[1]));
    if (!t) return sendError(res, 404, "task not found");
    Object.assign(t, body, { updatedAt: Date.now() });
    if (t.caseId) addEvent(t.caseId, "task.updated", { task: t }, body.actor || "operator");
    persistSoon();
    broadcastToSubscribers({ type: "task.updated", task: t, caseId: t.caseId });
    broadcastLegacy("task", t);
    return sendJSON(res, 200, t);
  }

  if (pathname === "/api/guidance" && req.method === "POST") {
    // Forward the POV frame to Claude (vision) → MARCH-structured guidance.
    // Operator APPROVES before it reaches the wearer. No key/frame → free sample.
    const b = await readBody(req);
    const key = process.env.ANTHROPIC_API_KEY;
    if (!key || !b.frame) {
      return sendJSON(res, 200, { proposal: { assessment: "Sample assessment (no AI key set).", march: [{ step: "M", action: "Control massive bleeding — firm direct pressure / tourniquet high & tight." }], banner: "Apply firm direct pressure now", steps: ["Apply firm direct pressure", "If a limb bleed won't stop, tourniquet high & tight"] }, note: "stand-in (set ANTHROPIC_API_KEY for real per-injury guidance)" });
    }
    try {
      const mt = (String(b.frame).match(/^data:(image\/\w+);base64,/) || [])[1] || "image/jpeg";
      const data = String(b.frame).split(",")[1] || "";
      const model = process.env.ANTHROPIC_MODEL || "claude-haiku-4-5-20251001";
      const sys = "You are a TCCC-trained emergency physician guiding an UNTRAINED bystander wearing smart glasses in a war/emergency zone. From the first-person photo (and optional hint), assess and direct the SAFEST next lay actions only (no invasive procedures). Reply with ONLY a JSON object: {\"assessment\":string, \"march\":[{\"step\":\"M|A|R|C|H\",\"action\":string}], \"banner\":string (ONE short imperative for the glasses display), \"steps\":[string]}. MARCH = Massive hemorrhage, Airway, Respiration, Circulation, Head/Hypothermia. If the image is unclear, say so in assessment and give the safest next step.";
      const r = await fetch("https://api.anthropic.com/v1/messages", {
        method: "POST",
        headers: { "x-api-key": key, "anthropic-version": "2023-06-01", "content-type": "application/json" },
        body: JSON.stringify({ model, max_tokens: 800, system: sys, messages: [{ role: "user", content: [{ type: "image", source: { type: "base64", media_type: mt, data } }, { type: "text", text: "Hint from operator: " + (b.hint || "none") + ". Return only the JSON object." }] }] }),
      });
      const j = await r.json();
      if (!r.ok) return sendJSON(res, 200, { error: (j.error && j.error.message) || ("AI HTTP " + r.status), proposal: { banner: "(AI unavailable — guide manually)" } });
      const txt = (j.content || []).filter((c) => c.type === "text").map((c) => c.text).join("");
      let parsed; try { parsed = JSON.parse(txt.slice(txt.indexOf("{"), txt.lastIndexOf("}") + 1)); } catch { parsed = { assessment: txt, march: [], banner: "", steps: [] }; }
      return sendJSON(res, 200, { proposal: parsed, model, usage: j.usage || null });
    } catch (e) { return sendJSON(res, 200, { error: String(e), proposal: { banner: "(AI error — guide manually)" } }); }
  }

  return sendError(res, 404, "unknown endpoint");
}

const httpServer = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://${req.headers.host || "localhost"}`);
  const pathname = decodeURIComponent(url.pathname);

  if (pathname.startsWith("/api/")) {
    try { return await handleApi(req, res, url); }
    catch (e) {
      const code = e.status || 500;
      if (code >= 500) console.log("api error:", e);
      return sendError(res, code, e.message || "server error");
    }
  }

  // Static file serving from public/ (path-traversal safe).
  const reqPath = pathname === "/" ? "/index.html" : pathname;
  const publicDir = path.join(__dirname, "public");
  const filePath = path.normalize(path.join(publicDir, reqPath));
  if (!filePath.startsWith(publicDir)) {
    res.writeHead(403);
    res.end("Forbidden");
    return;
  }
  fs.readFile(filePath, (err, data) => {
    if (err) {
      res.writeHead(404);
      res.end("Not found");
      return;
    }
    res.writeHead(200, { "Content-Type": MIME[path.extname(filePath)] || "text/plain", "Cache-Control": "no-cache" });
    res.end(data);
  });
});

/* ============================================================================
   WebSocket: signaling + backend subscriptions
============================================================================ */
const wss = new WebSocketServer({ server: httpServer });

wss.on("connection", (ws, req) => {
  let currentRoom = null;
  let role = null; // 'user' | 'operator'
  ws.caseSubscriptions = new Set();
  const ip = req.headers["x-forwarded-for"] || req.socket.remoteAddress;
  console.log(`[WS] connect ${ip} ${req.url || "/"}`);

  ws.on("message", (data) => {
    let msg;
    try { msg = JSON.parse(data); } catch { return; }

    switch (msg.type) {
      // --- User (glasses) opens a room ---
      // Optional extension for the backend flow: {type:"create", caseId:"C-10"}
      // reuses the case roomCode returned by POST /api/cases.
      case "create": {
        const linkedCase = msg.caseId ? findCase(String(msg.caseId)) : null;
        const preferred = linkedCase?.roomCode && !rooms.has(linkedCase.roomCode) ? linkedCase.roomCode : null;
        const code = preferred || uniqueRoomCode();
        rooms.set(code, { user: ws, operator: null, destroyTimer: null });
        currentRoom = code;
        role = "user";
        if (linkedCase) {
          linkedCase.roomCode = code;
          linkedCase.updatedAt = Date.now();
          persistSoon();
          broadcastCase(linkedCase, "case.updated");
        }
        send(ws, { type: "room_created", room: code, ...(linkedCase ? { caseId: linkedCase.id } : {}) });
        console.log(`[Room] created ${code}${linkedCase ? ` for ${linkedCase.id}` : ""}`);
        break;
      }

      // --- User reconnects after backgrounding ---
      case "rejoin": {
        const room = rooms.get(msg.room);
        if (!room) return send(ws, { type: "error", message: "Room not found" });
        if (room.destroyTimer) { clearTimeout(room.destroyTimer); room.destroyTimer = null; }
        room.user = ws;
        currentRoom = msg.room;
        role = "user";
        send(ws, { type: "room_rejoined", room: msg.room });
        if (room.operator && room.operator.readyState === 1) send(ws, { type: "peer_joined" });
        console.log(`[Room] user rejoined ${msg.room}`);
        break;
      }

      // --- Operator joins an existing room ---
      case "join": {
        const room = rooms.get(msg.room);
        if (!room) return send(ws, { type: "error", message: "Room not found" });
        // Allow a fresh operator to take over a stale/closed one (avoids
        // spurious "Room is full" when a previous tab is left open or died).
        if (room.operator && room.operator.readyState === 1) {
          return send(ws, { type: "error", message: "Room is full" });
        }
        room.operator = ws;
        currentRoom = msg.room;
        role = "operator";
        send(ws, { type: "room_joined" });
        send(room.user, { type: "peer_joined" });
        console.log(`[Room] operator joined ${msg.room}`);
        break;
      }

      // --- Relay SDP / ICE to the other peer ---
      case "offer":
      case "answer":
      case "candidate": {
        const room = rooms.get(currentRoom);
        if (!room) return;
        const target = role === "user" ? room.operator : room.user;
        send(target, msg);
        break;
      }

      // --- Backend realtime subscriptions ---
      case "subscribe_sync": {
        syncClients.add(ws);
        send(ws, { type: "sync_snapshot", cases: store.cases, tasks: store.tasks });
        break;
      }
      case "subscribe_cases": {
        syncClients.add(ws);
        send(ws, { type: "cases.snapshot", cases: store.cases });
        break;
      }
      case "subscribe_case": {
        syncClients.add(ws);
        if (msg.caseId) ws.caseSubscriptions.add(String(msg.caseId));
        const snapshot = msg.caseId ? caseSnapshot(String(msg.caseId)) : null;
        if (snapshot) send(ws, { type: "case.snapshot", caseId: snapshot.id, case: snapshot });
        else send(ws, { type: "error", message: "case not found" });
        break;
      }
      case "unsubscribe_case": {
        if (msg.caseId) ws.caseSubscriptions.delete(String(msg.caseId));
        break;
      }
      case "ping": {
        send(ws, { type: "pong", ts: Date.now() });
        break;
      }
    }
  });

  ws.on("error", (err) => console.log(`[WS] error ${role} ${currentRoom}: ${err.message}`));

  ws.on("close", () => {
    syncClients.delete(ws);
    console.log(`[WS] close ${role} ${currentRoom}`);
    if (!currentRoom || !rooms.has(currentRoom)) return;
    const room = rooms.get(currentRoom);
    const other = role === "user" ? room.operator : room.user;
    send(other, { type: "peer_left" });

    if (role === "user") {
      room.user = null;
      room.destroyTimer = setTimeout(() => {
        const r = rooms.get(currentRoom);
        if (r && (!r.user || r.user.readyState !== 1)) {
          send(r.operator, { type: "error", message: "Stream ended" });
          rooms.delete(currentRoom);
          console.log(`[Room] destroyed ${currentRoom}`);
        }
      }, ROOM_GRACE_PERIOD_MS);
    } else {
      room.operator = null;
    }
  });
});

httpServer.listen(PORT, "0.0.0.0", () => {
  console.log(`SaveVision operator-web on http://localhost:${PORT}`);
});
