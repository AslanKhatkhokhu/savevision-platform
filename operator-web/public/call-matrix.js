/* ============================================================================
   SaveVision — operator answers an incoming SV1| call over Matrix.

   The iOS wearer app is the OFFERER (one-way media wearer → operator). It posts
   WebRTC signaling as Matrix m.room.message bodies prefixed "SV1|":
     SV1|{"kind":"offer","sdp":"…","ts":…}
     SV1|{"kind":"candidate","candidate":"…","sdpMid":"…","sdpMLineIndex":0,"ts":…}
     SV1|{"kind":"hangup","ts":…}
   (matches ios-app/.../SignalingMessage.swift)

   This module: listens to the room (Matrix /sync), and when an offer arrives it
   answers — setRemoteDescription → createAnswer → send SV1|answer → trickle
   SV1|candidate — then renders the wearer's video.
============================================================================ */
async function answerMatrixCall({ hs, token, roomId, videoEl, log }) {
  log = log || ((m) => console.log("[call]", m));
  hs = hs.replace(/\/$/, "");
  const enc = encodeURIComponent;
  const auth = { Authorization: "Bearer " + token, "Content-Type": "application/json" };

  let ice = [{ urls: "stun:stun.l.google.com:19302" }];
  try { ice = (await fetch("/api/ice").then((r) => r.json())).iceServers || ice; } catch {}
  const pc = new RTCPeerConnection({ iceServers: ice });

  pc.ontrack = (e) => {
    let s = e.streams && e.streams[0];
    if (!s) { s = new MediaStream(); s.addTrack(e.track); }   // some senders add a track with no stream
    videoEl.style.display = ""; videoEl.srcObject = s; videoEl.muted = true;
    videoEl.play && videoEl.play().catch(() => {});
    log("● Live POV — " + e.track.kind + " track received");
  };
  pc.oniceconnectionstatechange = () => log("ice: " + pc.iceConnectionState);
  pc.onconnectionstatechange = () => {
    log("conn: " + pc.connectionState);
    if (pc.connectionState === "failed") log("media failed — the operator likely needs its own TURN (set TURN_* secrets)");
  };
  setTimeout(() => { if (!videoEl.srcObject) log("no media after 9s — ICE didn't complete; operator probably needs a TURN server"); }, 9000);

  let txn = 0;
  function sendSV1(obj) {
    obj.ts = Date.now();
    return fetch(`${hs}/_matrix/client/v3/rooms/${enc(roomId)}/send/m.room.message/sv${Date.now()}_${txn++}`,
      { method: "PUT", headers: auth, body: JSON.stringify({ msgtype: "m.text", body: "SV1|" + JSON.stringify(obj) }) });
  }
  pc.onicecandidate = (e) => {
    if (e.candidate) sendSV1({ kind: "candidate", candidate: e.candidate.candidate, sdpMid: e.candidate.sdpMid, sdpMLineIndex: e.candidate.sdpMLineIndex });
  };

  let answered = false; const pending = [];
  const addCand = async (m) => { try { await pc.addIceCandidate({ candidate: m.candidate, sdpMid: m.sdpMid, sdpMLineIndex: m.sdpMLineIndex }); } catch {} };
  async function handle(body) {
    let m; try { m = JSON.parse(body.slice(4)); } catch { return; }
    if (m.kind === "offer" && !answered) {
      answered = true;
      log("incoming offer — answering…");
      await pc.setRemoteDescription({ type: "offer", sdp: m.sdp });
      const ans = await pc.createAnswer();
      await pc.setLocalDescription(ans);
      await sendSV1({ kind: "answer", sdp: ans.sdp });
      log("answered — connecting media…");
      for (const c of pending.splice(0)) await addCand(c);   // flush early candidates
    } else if (m.kind === "candidate") {
      if (pc.remoteDescription && pc.remoteDescription.type) await addCand(m);
      else pending.push(m);                                   // queue until the offer is set
    } else if (m.kind === "hangup") {
      log("caller hung up"); pc.close();
    }
  }

  // Prime the sync position FIRST, so no candidate is missed between backfill and the loop.
  let stop = false, since = null;
  try { since = (await fetch(`${hs}/_matrix/client/v3/sync?timeout=0`, { headers: auth }).then((r) => r.json())).next_batch; } catch {}

  // Backfill: pick up the offer (and early candidates) the app sent before we answered.
  try {
    const msgs = await fetch(`${hs}/_matrix/client/v3/rooms/${enc(roomId)}/messages?dir=b&limit=40`, { headers: auth }).then((r) => r.json());
    const evs = (msgs.chunk || []).reverse().filter((e) => e.type === "m.room.message" && (e.content?.body || "").startsWith("SV1|"));
    for (const e of evs) await handle(e.content.body);
  } catch {}

  // Live loop from the primed position (re-reads the boundary harmlessly; no gap).
  log(answered ? "answering…" : "waiting for the app to call…");
  (async function loop() {
    while (!stop) {
      try {
        const d = await fetch(`${hs}/_matrix/client/v3/sync?timeout=25000&since=${enc(since)}`, { headers: auth }).then((r) => r.json());
        since = d.next_batch;
        const tl = d.rooms?.join?.[roomId]?.timeline?.events || [];
        for (const ev of tl) if (ev.type === "m.room.message" && (ev.content?.body || "").startsWith("SV1|")) await handle(ev.content.body);
      } catch { await new Promise((r) => setTimeout(r, 1500)); }
    }
  })();

  return {
    pc,
    stop: () => { stop = true; try { pc.close(); } catch {} },                                  // local teardown only — does NOT end the caller's call
    hangup: () => { stop = true; try { sendSV1({ kind: "hangup" }); } catch {} try { pc.close(); } catch {} },
  };
}
window.answerMatrixCall = answerMatrixCall;
