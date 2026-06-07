/* ============================================================================
   SaveVision — operator (doctor) client.

   Data flow is STRICTLY ONE-WAY: doctor → wearer. The wearer only publishes
   their live POV video + audio; they never send data back. The doctor pushes:
     - guidance  : instruction text  (banner on the HUD)
     - drawing   : freehand strokes   (overlay on the HUD)
     - image     : example diagram    (e.g. how to pack a wound)
     - map       : heading + label    (direction marker on the HUD)

   TRANSPORT — production vs. dev:
     Production rides MATRIX end to end — video/audio over MatrixRTC (Element
     Call), and the doctor→wearer payloads above as custom E2E-encrypted Matrix
     room events. See ../MATRIX.md.
     This file is the LOCAL DEV HARNESS: a plain WebRTC data channel stands in
     for Matrix so you can demo without a homeserver. The message shapes are
     identical, so swapping the transport doesn't change the payloads.

   See ../PROTOCOL.md for the wire contract.
============================================================================ */

const els = {
  room: document.getElementById("room"),
  joinBtn: document.getElementById("joinBtn"),
  status: document.getElementById("status"),
  video: document.getElementById("remoteVideo"),
  placeholder: document.getElementById("placeholder"),
  guidance: document.getElementById("guidance"),
  sendBtn: document.getElementById("sendBtn"),
  draw: document.getElementById("draw"),
  freezeBtn: document.getElementById("freezeBtn"),
  clearBtn: document.getElementById("clearBtn"),
  sendDrawBtn: document.getElementById("sendDrawBtn"),
  imgInput: document.getElementById("imgInput"),
  sendImgBtn: document.getElementById("sendImgBtn"),
  mapLabel: document.getElementById("mapLabel"),
  sendMapBtn: document.getElementById("sendMapBtn"),
  liveMapBtn: document.getElementById("liveMapBtn"),
  aiGenBtn: document.getElementById("aiGenBtn"),
  aiProposal: document.getElementById("aiProposal"),
  aiImg: document.getElementById("aiImg"),
  aiApprove: document.getElementById("aiApprove"),
  aiDiscard: document.getElementById("aiDiscard"),
  mxHs: document.getElementById("mxHs"),
  mxUser: document.getElementById("mxUser"),
  mxSecret: document.getElementById("mxSecret"),
  mxRoom: document.getElementById("mxRoom"),
  mxConnect: document.getElementById("mxConnect"),
  mxStatus: document.getElementById("mxStatus"),
  mxCall: document.getElementById("mxCall"),
  mxAnswer: document.getElementById("mxAnswer"),
  log: document.getElementById("log"),
};
let liveMapOn = false;

let ws = null;
let pc = null;
let channel = null;          // doctor → wearer payload channel
let penColor = "#00e0ff";
let bearing = 0;
let strokes = [];            // [{ color, points: [{x,y} normalised 0..1] }]
let drawing = false;

const ctx = els.draw.getContext("2d");

function setStatus(text, kind) {
  els.status.textContent = text;
  els.status.className = "status status--" + kind;
}
function log(msg, cls = "") {
  const li = document.createElement("li");
  li.textContent = msg;
  if (cls) li.className = cls;
  els.log.prepend(li);
}
function channelReady() { return channel && channel.readyState === "open"; }

function setSendEnabled(on) {
  [els.sendBtn, els.sendDrawBtn, els.sendImgBtn, els.sendMapBtn, els.liveMapBtn].forEach(
    (b) => (b.disabled = !on)
  );
}

async function getIceServers() {
  try { return (await (await fetch("/api/ice")).json()).iceServers; }
  catch { return [{ urls: "stun:stun.l.google.com:19302" }]; }
}
function wsUrl() {
  return `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}`;
}

// ---- signaling ----
async function join() {
  const room = els.room.value.trim().toUpperCase();
  if (room.length !== 6) return log("Room code must be 6 characters", "err");
  ws = new WebSocket(wsUrl());
  ws.onopen = () => { setStatus("Joining…", "idle"); ws.send(JSON.stringify({ type: "join", room })); };
  ws.onerror = () => setStatus("Connection error", "error");
  ws.onclose = () => setStatus("Disconnected", "idle");
  ws.onmessage = (e) => handleSignal(JSON.parse(e.data));
}

async function ensurePeer() {
  if (pc) return pc;
  pc = new RTCPeerConnection({ iceServers: await getIceServers() });
  pc.ontrack = (e) => {
    els.video.srcObject = e.streams[0];
    els.video.muted = true;             // required so the browser will autoplay
    els.video.play().catch(() => {});   // explicit play in case autoplay is blocked
    els.placeholder.style.display = "none";
    setStatus("Live", "live");
  };
  pc.onicecandidate = (e) => { if (e.candidate) ws.send(JSON.stringify({ type: "candidate", candidate: e.candidate })); };
  // The wearer (offerer) creates the channel; we send doctor→wearer payloads on it.
  pc.ondatachannel = (e) => {
    channel = e.channel;
    channel.onopen = () => { setSendEnabled(true); log("Guidance channel open"); };
    channel.onclose = () => setSendEnabled(false);
  };
  pc.onconnectionstatechange = () => {
    if (["failed", "disconnected", "closed"].includes(pc.connectionState)) setStatus("Peer lost", "error");
  };
  return pc;
}

async function handleSignal(msg) {
  switch (msg.type) {
    case "room_joined":
      setStatus("Waiting for wearer’s stream…", "idle");
      log(`Joined room ${els.room.value.toUpperCase()}`);
      break;
    case "offer": {
      const peer = await ensurePeer();
      await peer.setRemoteDescription(new RTCSessionDescription(msg));
      const answer = await peer.createAnswer();
      await peer.setLocalDescription(answer);
      ws.send(JSON.stringify({ type: "answer", sdp: answer.sdp }));
      break;
    }
    case "candidate":
      if (pc && msg.candidate) { try { await pc.addIceCandidate(new RTCIceCandidate(msg.candidate)); } catch {} }
      break;
    case "peer_left": setStatus("Wearer disconnected", "error"); log("Wearer left", "err"); break;
    case "error": setStatus(msg.message, "error"); log(msg.message, "err"); break;
  }
}

// ---- the one-way payload sender (Matrix event in production) ----
function send(payload) {
  const p = { ...payload, ts: Date.now() };
  let sent = false;
  if (channelReady()) { channel.send(JSON.stringify(p)); sent = true; }   // local glasses-sim peer
  if (typeof MX !== "undefined" && MX.connected()) {                       // real Matrix room (threaded)
    MX.send(p).catch((e) => log("Matrix: " + e.message, "err"));
    sent = true;
  }
  if (!sent) log("Not connected — connect Matrix or join a glasses code", "err");
}

function sendGuidance(text) {
  const message = (text ?? els.guidance.value).trim();
  if (!message) return;
  send({ kind: "guidance", text: message });
  log(`→ text: ${message}`, "sent");
  els.guidance.value = "";
}

// ---- drawing ----
function resizeCanvas() {
  els.draw.width = els.draw.clientWidth;
  els.draw.height = els.draw.clientHeight;
  repaint();
}
function repaint() {
  ctx.clearRect(0, 0, els.draw.width, els.draw.height);
  for (const s of strokes) {
    ctx.strokeStyle = s.color; ctx.lineWidth = 4; ctx.lineCap = "round"; ctx.lineJoin = "round";
    ctx.beginPath();
    s.points.forEach((p, i) => {
      const x = p.x * els.draw.width, y = p.y * els.draw.height;
      i ? ctx.lineTo(x, y) : ctx.moveTo(x, y);
    });
    ctx.stroke();
  }
}
function pos(e) {
  const r = els.draw.getBoundingClientRect();
  return { x: (e.clientX - r.left) / r.width, y: (e.clientY - r.top) / r.height };
}
els.draw.addEventListener("pointerdown", (e) => { drawing = true; strokes.push({ color: penColor, points: [pos(e)] }); repaint(); });
els.draw.addEventListener("pointermove", (e) => { if (!drawing) return; strokes[strokes.length - 1].points.push(pos(e)); repaint(); });
window.addEventListener("pointerup", () => { drawing = false; });

function sendDrawing() {
  if (!strokes.length) return log("Nothing drawn", "err");
  // Normalised coords (0..1) so the wearer's display maps them at any resolution.
  send({ kind: "drawing", strokes });
  log(`→ drawing (${strokes.length} strokes)`, "sent");
}
function clearDrawing(local = false) {
  strokes = []; repaint();
  if (!local) { send({ kind: "clear" }); log("→ clear", "sent"); }
}

// ---- example image (downscaled, single message; Matrix mxc:// upload in prod) ----
function sendImage(file) {
  if (!file) return;
  const img = new Image();
  img.onload = () => {
    const max = 640, scale = Math.min(1, max / Math.max(img.width, img.height));
    const c = document.createElement("canvas");
    c.width = Math.round(img.width * scale); c.height = Math.round(img.height * scale);
    c.getContext("2d").drawImage(img, 0, 0, c.width, c.height);
    const dataUrl = c.toDataURL("image/jpeg", 0.6);
    send({ kind: "image", dataUrl, caption: file.name });
    log(`→ image: ${file.name}`, "sent");
  };
  img.src = URL.createObjectURL(file);
}

// ---- map / direction ----
function sendMap() {
  send({ kind: "map", label: els.mapLabel.value.trim() || "Go", bearing });
  log(`→ map: ${bearing}° ${els.mapLabel.value}`, "sent");
}

// ---- wiring ----
els.joinBtn.addEventListener("click", join);
els.room.addEventListener("keydown", (e) => { if (e.key === "Enter") join(); });
els.sendBtn.addEventListener("click", () => sendGuidance());
els.guidance.addEventListener("keydown", (e) => { if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) sendGuidance(); });
document.querySelectorAll(".chip").forEach((c) => c.addEventListener("click", () => sendGuidance(c.dataset.msg)));

document.querySelectorAll(".tool").forEach((t) =>
  t.addEventListener("click", () => {
    document.querySelectorAll(".tool").forEach((x) => x.classList.remove("is-active"));
    t.classList.add("is-active"); penColor = t.dataset.color;
  })
);
els.freezeBtn.addEventListener("click", () => {
  // Freeze: snapshot the current video frame and send it as an image to draw context on.
  if (!els.video.videoWidth) return log("No video to freeze", "err");
  const c = document.createElement("canvas");
  c.width = 640; c.height = Math.round(640 * els.video.videoHeight / els.video.videoWidth);
  c.getContext("2d").drawImage(els.video, 0, 0, c.width, c.height);
  send({ kind: "image", dataUrl: c.toDataURL("image/jpeg", 0.6), caption: "frozen frame" });
  log("→ frozen frame", "sent");
});
els.clearBtn.addEventListener("click", () => clearDrawing());
els.sendDrawBtn.addEventListener("click", sendDrawing);
els.sendImgBtn.addEventListener("click", () => sendImage(els.imgInput.files[0]));
els.imgInput.addEventListener("change", () => { els.sendImgBtn.disabled = !(channelReady() || (typeof MX !== "undefined" && MX.connected())) || !els.imgInput.files.length; });
// reference-photo gallery → send the image by URL (rendered on the wearer's HUD)
document.querySelectorAll("#gallery img").forEach((g) =>
  g.addEventListener("click", () => { send({ kind: "image", url: g.src, caption: g.dataset.l }); log(`→ photo: ${g.dataset.l}`, "sent"); })
);

// AI guidance — propose → operator approves → send. The proposal here is a
// stand-in (no cost). In production this comes from a vision model: capture a
// POV frame, ask Claude (vision) to analyse the injury and return guidance, and
// show its proposed image/annotation here for approval. Nothing reaches the
// wearer until "Approve & send". See ../../AI_GUIDANCE.md.
// Capture the current POV frame and ask Claude for MARCH-structured guidance.
let aiBanner = "", aiSteps = [];
function grabFrame() {
  const v = [...document.querySelectorAll("video")].find((x) => x.srcObject && x.videoWidth > 0) || els.video;
  if (!v || !v.videoWidth) return null;
  try {
    const w = Math.min(768, v.videoWidth), h = Math.round(w * v.videoHeight / v.videoWidth);
    const c = document.createElement("canvas"); c.width = w; c.height = h;
    c.getContext("2d").drawImage(v, 0, 0, w, h);
    return c.toDataURL("image/jpeg", 0.6);
  } catch { return null; }
}
els.aiGenBtn.addEventListener("click", async () => {
  const aiText = document.getElementById("aiText");
  els.aiProposal.style.display = "block"; aiText.textContent = "Analysing the POV frame…";
  log("AI: analysing scene…");
  try {
    const res = await fetch("/api/guidance", { method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ frame: grabFrame(), hint: (els.guidance.value || "").trim() }) }).then((r) => r.json());
    const pr = res.proposal || {};
    aiBanner = pr.banner || (pr.steps && pr.steps[0]) || "";
    aiSteps = pr.steps || [];
    const march = (pr.march || []).map((x) => `  ${x.step}: ${x.action}`).join("\n");
    aiText.textContent =
      (pr.assessment ? "⚕ " + pr.assessment + "\n\n" : "") +
      (march ? "MARCH:\n" + march + "\n\n" : "") +
      (pr.banner ? "→ Banner: " + pr.banner : "") +
      (res.error ? "\n\n[AI: " + res.error + "]" : "") +
      (res.note ? "\n\n(" + res.note + ")" : "");
    log(res.model ? `AI proposed (${res.model}) — review & approve` : "AI proposed (sample) — review & approve");
  } catch (e) { aiText.textContent = "AI error: " + e.message; }
});
els.aiApprove.addEventListener("click", () => {
  if (aiBanner) send({ kind: "guidance", text: aiBanner });
  els.aiProposal.style.display = "none";
  log("→ AI guidance approved & sent" + (aiBanner ? ": " + aiBanner : ""), "sent");
});
els.aiDiscard.addEventListener("click", () => { els.aiProposal.style.display = "none"; log("AI guidance discarded"); });

// --- Matrix: connect + open the case room; after this, every send() above also
//     posts a threaded org.savevision.* event into the room (the real transport). ---
// Watch the wearer's live POV IN the operator app: join the room's MatrixRTC
// (Element Call / LiveKit) call and render the video track in the POV area.
els.mxCall.addEventListener("click", async () => {
  if (typeof MX === "undefined" || !MX.connected()) {
    els.mxStatus.textContent = "Connect to Matrix first"; els.mxStatus.style.color = "var(--danger)"; return;
  }
  els.placeholder.style.display = "none";
  setStatus("Joining call…", "live");
  try {
    await startLivePOV({ hs: MX.hs, token: MX.token, userId: MX.userId, roomId: MX.roomId,
      videoEl: els.video, log: (m) => { els.mxStatus.textContent = m; els.mxStatus.style.color = "var(--accent)"; } });
  } catch (e) {
    setStatus("Call error", "error"); els.mxStatus.textContent = "✗ " + e.message; els.mxStatus.style.color = "var(--danger)";
  }
});

// Answer an incoming SV1| call that the wearer app starts over Matrix.
els.mxAnswer.addEventListener("click", async () => {
  if (typeof MX === "undefined" || !MX.connected()) { els.mxStatus.textContent = "Connect to Matrix first"; els.mxStatus.style.color = "var(--danger)"; return; }
  els.placeholder.style.display = "none"; setStatus("Answering…", "live");
  try {
    await answerMatrixCall({ hs: MX.hs, token: MX.token, roomId: MX.roomId, videoEl: els.video,
      log: (m) => { els.mxStatus.textContent = m; els.mxStatus.style.color = "var(--accent)"; } });
  } catch (e) { setStatus("Call error", "error"); els.mxStatus.textContent = "✗ " + e.message; els.mxStatus.style.color = "var(--danger)"; }
});

els.mxConnect.addEventListener("click", async () => {
  try {
    els.mxStatus.textContent = "Connecting…";
    const uid = await MX.login(els.mxHs.value.trim(), els.mxUser.value.trim(), els.mxSecret.value);
    await MX.openCase(els.mxRoom.value.trim(), { id: "session", note: "operator session", ts: Date.now() });
    els.mxStatus.textContent = "✓ " + uid + " · room ready";
    els.mxStatus.style.color = "var(--accent)";
    setSendEnabled(true);
    send({ kind: "clear" });   // wipe any image/guidance left over from a previous call
    els.mxSecret.value = "";   // don't keep the secret in the field
    log("Matrix connected — guidance now posts to the room", "sent");
  } catch (e) {
    els.mxStatus.textContent = "✗ " + e.message;
    els.mxStatus.style.color = "var(--danger)";
  }
});
// Doctor→wearer controls need EITHER a data channel OR Matrix — enable as soon as Matrix is up
// (covers the console handoff + the annotate auto-connect, not just the Connect button).
setInterval(() => { if (typeof MX !== "undefined" && MX.connected()) setSendEnabled(true); }, 1200);
document.querySelectorAll(".dir").forEach((d) =>
  d.addEventListener("click", () => {
    document.querySelectorAll(".dir").forEach((x) => x.classList.remove("is-active"));
    d.classList.add("is-active"); bearing = Number(d.dataset.bearing);
  })
);
els.sendMapBtn.addEventListener("click", sendMap);

// Live real-map on the wearer's glasses — operator toggles on/off.
els.liveMapBtn.addEventListener("click", () => {
  liveMapOn = !liveMapOn;
  send({ kind: "livemap", on: liveMapOn, lat: 48.2082, lng: 16.3738, zoom: 16, label: els.mapLabel.value.trim() || "To collection point" });
  els.liveMapBtn.textContent = liveMapOn ? "🗺 Turn live map OFF" : "🗺 Turn live map ON";
  log(`→ live map ${liveMapOn ? "ON" : "OFF"}`, "sent");
});

window.addEventListener("resize", resizeCanvas);
new ResizeObserver(resizeCanvas).observe(els.draw);
resizeCanvas();
