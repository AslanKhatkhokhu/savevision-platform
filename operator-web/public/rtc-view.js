/* ============================================================================
   SaveVision — in-app live viewer (MatrixRTC / Element Call over LiveKit).

   - ONE shared grid that aggregates streams from MULTIPLE rooms, so the operator
     account can watch EVERY caller's stream at once (call startLivePOV per room).
   - Subscribes to all remote VIDEO + AUDIO tracks (operator hears the scene).
   - Publishes the operator mic (two-way audio) unless {mic:false}.
   - Click a tile to enlarge; click again for the grid.

   Token flow: OpenID request_token → {livekit_service_url}/sfu/get → connect.
============================================================================ */

// ---- shared grid state across rooms ----
let svGrid = null;
const svTiles = new Map();   // key "room/psid/tsid" -> { tile, video }
const svAudio = new Map();   // key -> { track, el }
const svRooms = new Map();   // roomId -> Room

function svEnsureGrid(stage) {
  if (!document.getElementById("rtcGridStyle")) {
    const st = document.createElement("style"); st.id = "rtcGridStyle";
    st.textContent = `
      #rtcGrid{position:absolute;inset:0;display:grid;gap:4px;padding:4px;background:#000;z-index:1}
      #rtcGrid .tile{position:relative;background:#06120d;border:1px solid #1f2b25;border-radius:6px;overflow:hidden;cursor:pointer}
      #rtcGrid video{width:100%;height:100%;object-fit:contain;background:#000}
      #rtcGrid .tile .lbl{position:absolute;left:6px;bottom:6px;background:#000a;color:#00e0ff;font:11px system-ui;padding:2px 8px;border-radius:999px}
      #rtcGrid.focusone .tile{display:none} #rtcGrid.focusone .tile.focused{display:block}`;
    document.head.appendChild(st);
  }
  if (!svGrid || !document.body.contains(svGrid)) { svGrid = document.createElement("div"); svGrid.id = "rtcGrid"; stage.appendChild(svGrid); }
  return svGrid;
}
function svLayout() { const n = Math.max(1, svTiles.size); svGrid.style.gridTemplateColumns = `repeat(${Math.ceil(Math.sqrt(n))},1fr)`; }
function svTileFor(key, label) {
  let t = svTiles.get(key); if (t) return t;
  const tile = document.createElement("div"); tile.className = "tile";
  const v = document.createElement("video"); v.autoplay = true; v.playsInline = true; v.muted = true;
  const lbl = document.createElement("div"); lbl.className = "lbl"; lbl.textContent = label || "stream";
  tile.append(v, lbl);
  tile.onclick = () => {
    if (svGrid.classList.contains("focusone") && tile.classList.contains("focused")) { svGrid.classList.remove("focusone"); tile.classList.remove("focused"); svGrid.style.gridTemplateColumns = ""; svLayout(); }
    else { svGrid.querySelectorAll(".tile").forEach((x) => x.classList.remove("focused")); tile.classList.add("focused"); svGrid.classList.add("focusone"); svGrid.style.gridTemplateColumns = "1fr"; }
  };
  svGrid.appendChild(tile); t = { tile, video: v }; svTiles.set(key, t); svLayout(); return t;
}
function svRemoveTile(key) { const t = svTiles.get(key); if (t) { t.tile.remove(); svTiles.delete(key); if (!svGrid.classList.contains("focusone")) svLayout(); } }
function svStopAll() {
  for (const room of svRooms.values()) { try { room.disconnect(); } catch {} }
  svRooms.clear(); svTiles.clear();
  for (const a of svAudio.values()) { try { a.track.detach(); } catch {} a.el.remove && a.el.remove(); }
  svAudio.clear();
  if (svGrid) { svGrid.innerHTML = ""; svGrid.classList.remove("focusone"); svGrid.style.gridTemplateColumns = ""; }
}

async function startLivePOV({ hs, token, userId, roomId, videoEl, log, append, mic }) {
  log = log || ((m) => console.log("[rtc]", m));
  if (!window.LivekitClient) { log("LiveKit SDK not loaded"); return; }
  hs = hs.replace(/\/$/, "");

  log("Authorising for the call…");
  const oid = await fetch(`${hs}/_matrix/client/v3/user/${encodeURIComponent(userId)}/openid/request_token`,
    { method: "POST", headers: { "Content-Type": "application/json", Authorization: "Bearer " + token }, body: "{}" }).then((r) => r.json());
  const wk = await fetch(`${hs}/.well-known/matrix/client`).then((r) => r.json()).catch(() => ({}));
  const sfu = ((wk["org.matrix.msc4143.rtc_foci"] || []).find((f) => f.type === "livekit") || {}).livekit_service_url;
  if (!sfu) { log("No LiveKit focus in well-known"); return; }
  const tok = await fetch(`${sfu.replace(/\/$/, "")}/sfu/get`,
    { method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ room: roomId, openid_token: oid, device_id: "OPERATOR" }) }).then((r) => r.json());
  if (!tok.url || !tok.jwt) { log("SFU did not return a token"); return; }

  const stage = videoEl.parentElement; videoEl.style.display = "none";
  svEnsureGrid(stage);
  if (!append) svStopAll();                  // fresh single-room view unless aggregating

  log("Connecting to the call…");
  const { Room, RoomEvent, VideoQuality } = window.LivekitClient;
  const room = new Room({ adaptiveStream: false, dynacast: false });
  const onTrack = (track, pub, p) => {
    if (!track) return;
    const key = roomId + "/" + p.sid + "/" + pub.trackSid;
    if (track.kind === "video") {
      const t = svTileFor(key, p.identity || p.name || "stream");
      track.attach(t.video);
      try { pub.setVideoQuality && pub.setVideoQuality(VideoQuality.HIGH); } catch {}
      log(`● ${svTiles.size} stream${svTiles.size > 1 ? "s" : ""} (click a tile to enlarge)`);
    } else if (track.kind === "audio") {
      const el = track.attach(); el.autoplay = true; document.body.appendChild(el); el.play && el.play().catch(() => {});
      svAudio.set(key, { track, el });
      log("🔊 audio from " + (p.identity || p.name || "caller"));
    }
  };
  room.on(RoomEvent.TrackSubscribed, (track, pub, p) => onTrack(track, pub, p));
  room.on(RoomEvent.TrackUnsubscribed, (track, pub, p) => { const k = roomId + "/" + p.sid + "/" + pub.trackSid; svRemoveTile(k); const a = svAudio.get(k); if (a) { try { a.track.detach(); } catch {} a.el.remove && a.el.remove(); svAudio.delete(k); } });
  room.on(RoomEvent.ParticipantDisconnected, (p) => { for (const k of [...svTiles.keys()]) if (k.startsWith(roomId + "/" + p.sid + "/")) svRemoveTile(k); });
  room.on(RoomEvent.Disconnected, (r) => log("call ended" + (r != null ? " (" + r + ")" : "")));
  room.on(RoomEvent.Reconnecting, () => log("reconnecting…"));
  if (RoomEvent.ConnectionStateChanged) room.on(RoomEvent.ConnectionStateChanged, (s) => log("conn: " + s));

  await room.connect(tok.url, tok.jwt, { autoSubscribe: true });
  svRooms.set(roomId, room);
  for (const p of room.remoteParticipants.values()) {
    for (const pub of p.trackPublications.values()) {
      if (pub.setSubscribed) { try { pub.setSubscribed(true); } catch {} }
      if (pub.track) onTrack(pub.track, pub, p);
    }
  }
  log("Joined call — waiting for video…");
  setTimeout(() => { if (!svTiles.size) log("joined, but no video yet — is the wearer publishing via MatrixRTC? (if the app uses SV1, use the 🔗 P2P button)"); }, 6000);
  if (mic !== false) {                       // publish operator mic so the wearer hears the operator
    try { await room.localParticipant.setMicrophoneEnabled(true); log("🎙 your mic is live — the caller can hear you"); }
    catch (e) { log("mic not enabled (" + ((e && e.message) || e) + ")"); }
  }
  window._svLiveRoom = room;
  return room;
}
window.startLivePOV = startLivePOV;
window.svStopAll = svStopAll;
