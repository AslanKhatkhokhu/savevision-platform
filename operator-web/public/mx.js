/* ============================================================================
   SaveVision — browser Matrix client (Client-Server HTTP API, no bundler).

   Lets the operator tool log in to the homeserver and post doctor→wearer
   guidance into a room as a Matrix THREAD (root = org.savevision.case; each
   guidance is a threaded reply). Same room the iOS/VisionClaw app joins.

   Note: this uses the raw CS API (fetch) so it runs in a plain page with no
   build step. It posts events UNENCRYPTED — fine for the test homeserver. For
   E2E (Olm/Megolm) switch to matrix-js-sdk with crypto (see matrix/matrix-client.js).
============================================================================ */
const MX = (() => {
  let hs = "", token = "", userId = "", roomId = "", rootEventId = "";

  async function api(method, path, body) {
    const res = await fetch(`${hs}/_matrix/client/v3${path}`, {
      method,
      headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      body: body ? JSON.stringify(body) : undefined,
    });
    const j = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error((j && (j.error || j.errcode)) || ("HTTP " + res.status));
    return j;
  }

  // Log in with a password, or (if that fails) treat the secret as an access token.
  async function login(homeserver, user, secret) {
    hs = (homeserver || "").replace(/\/$/, "");
    try {
      const r = await api("POST", "/login", { type: "m.login.password", identifier: { type: "m.id.user", user }, password: secret });
      token = r.access_token; userId = r.user_id;
    } catch {
      token = secret;
      const w = await api("GET", "/account/whoami");
      userId = w.user_id;
    }
    return userId;
  }

  // Join the case room and post the thread root.
  async function openCase(room, caseInfo) {
    roomId = room;
    try { await api("POST", `/join/${encodeURIComponent(room)}`, {}); } catch (e) { /* already joined */ }
    const root = await api("PUT", `/rooms/${encodeURIComponent(room)}/send/org.savevision.case/r${Date.now()}`, caseInfo || { id: "session" });
    rootEventId = root.event_id;
    return rootEventId;
  }

  // Upload a data: URL to the media repo and return its mxc:// URI.
  async function uploadDataUrl(dataUrl) {
    const m = /^data:([^;]+);base64,(.*)$/.exec(dataUrl || ""); if (!m) return null;
    const bin = atob(m[2]); const arr = new Uint8Array(bin.length);
    for (let i = 0; i < bin.length; i++) arr[i] = bin.charCodeAt(i);
    const res = await fetch(`${hs}/_matrix/media/v3/upload`, { method: "POST", headers: { "Content-Type": m[1], Authorization: "Bearer " + token }, body: arr });
    const j = await res.json().catch(() => ({}));
    return j.content_uri || null;
  }

  // Send doctor→wearer guidance in the format the WEARER APP renders on the lens
  // (SaveVisionHUDPayload + m.image — see ios-app DisplayOverlayModels.swift):
  //   • images → m.image (the app downloads the mxc and shows it on the glasses)
  //   • else   → SVHUD|{json} text message (parsed by the app, hidden from chat)
  async function send(payload) {
    if (!token || !roomId) return;
    const kind = payload.kind || "guidance";
    if (kind === "image" && (payload.dataUrl || payload.url)) {
      let mxc = payload.url && payload.url.startsWith("mxc://") ? payload.url : null;
      if (!mxc && payload.dataUrl) mxc = await uploadDataUrl(payload.dataUrl);
      if (mxc) {
        await api("PUT", `/rooms/${encodeURIComponent(roomId)}/send/m.room.message/img${Date.now()}`,
          { msgtype: "m.image", body: payload.caption || "operator image", url: mxc });
        return;
      }
      // non-mxc http(s) url → fall through and send as SVHUD with the url
    }
    const hud = { kind, ts: Date.now() };
    for (const k of ["text", "caption", "label", "bearing", "lat", "lng", "url", "dataUrl"]) if (payload[k] != null) hud[k] = payload[k];
    await api("PUT", `/rooms/${encodeURIComponent(roomId)}/send/m.room.message/hud${Date.now()}`,
      { msgtype: "m.text", body: "SVHUD|" + JSON.stringify(hud) });
  }

  const connected = () => !!(token && roomId);
  return { login, openCase, send, connected,
    get userId() { return userId; }, get roomId() { return roomId; },
    get hs() { return hs; }, get token() { return token; } };
})();
