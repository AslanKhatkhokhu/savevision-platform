/* ============================================================================
   SaveVision — Matrix connection test (zero dependencies, Node 18+ global fetch).

   Verifies the core of the SaveVision↔Matrix integration against ANY homeserver:
     1. log in (password) → access token
     2. create a room (one emergency session)
     3. send a SaveVision guidance event  (org.savevision.guidance)
     4. read it back from the room timeline

   This proves auth + rooms + custom events work end to end. (End-to-end
   ENCRYPTION is a later step — it needs the Matrix SDK's crypto; this test uses
   a plaintext room just to validate connectivity and the event model.)

   Usage:
     HS=https://matrix.yourdomain USER=svc-doctor PASS=secret node connection-test.mjs
   or copy config.example.json → config.json and fill it in, then:
     node connection-test.mjs
============================================================================ */

import { readFileSync } from "node:fs";

// ---- config: env vars win; else config.json ----
let cfg = {};
try { cfg = JSON.parse(readFileSync(new URL("./config.json", import.meta.url))); } catch {}
const HS    = process.env.HS    || cfg.homeserverUrl;
const USER  = process.env.USER_ID || process.env.USER || cfg.user;
const PASS  = process.env.PASS  || cfg.password;
const TOKEN = process.env.TOKEN || cfg.accessToken;

if (!HS || (!TOKEN && (!USER || !PASS))) {
  console.error("Need HS + (TOKEN or USER+PASS). See config.example.json.");
  process.exit(1);
}
const base = HS.replace(/\/$/, "");

async function api(method, path, body, token) {
  const res = await fetch(`${base}/_matrix/client/v3${path}`, {
    method,
    headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await res.text();
  let json; try { json = JSON.parse(text); } catch { json = { raw: text }; }
  if (!res.ok) throw new Error(`${method} ${path} → ${res.status}: ${JSON.stringify(json)}`);
  return json;
}

(async () => {
  // 0. server reachable?
  const ver = await fetch(`${base}/_matrix/client/versions`).then(r => r.json());
  console.log("✓ homeserver reachable; versions:", (ver.versions || []).slice(-3).join(", "));

  // 1. auth
  let token = TOKEN, userId;
  if (!token) {
    const login = await api("POST", "/login", {
      type: "m.login.password",
      identifier: { type: "m.id.user", user: USER },
      password: PASS,
    });
    token = login.access_token; userId = login.user_id;
    console.log("✓ logged in as", userId);
  } else {
    const who = await api("GET", "/account/whoami", null, token);
    userId = who.user_id;
    console.log("✓ token valid for", userId);
  }

  // 2. create a session room
  const room = await api("POST", "/createRoom", {
    name: "SaveVision session (test)",
    preset: "private_chat",
    topic: "Connection test — safe to delete",
  }, token);
  console.log("✓ created room", room.room_id);

  // 3. send a SaveVision guidance event (the doctor→wearer payload model)
  const txn = `sv${Date.now()}`;
  const sent = await api(
    "PUT",
    `/rooms/${encodeURIComponent(room.room_id)}/send/org.savevision.guidance/${txn}`,
    { kind: "guidance", text: "Apply direct pressure now", ts: Date.now() },
    token
  );
  console.log("✓ sent org.savevision.guidance event", sent.event_id);

  // 4. read it back
  const msgs = await api(
    "GET",
    `/rooms/${encodeURIComponent(room.room_id)}/messages?dir=b&limit=5`,
    null,
    token
  );
  const found = (msgs.chunk || []).find(e => e.type === "org.savevision.guidance");
  if (found) console.log("✓ read it back:", JSON.stringify(found.content));
  else throw new Error("sent event not found in timeline");

  console.log("\n🎉 SaveVision ↔ Matrix works. Next: wire operator-web to send these events, and add E2E via the Matrix SDK.");
})().catch((e) => { console.error("\n✗ FAILED:", e.message); process.exit(1); });
