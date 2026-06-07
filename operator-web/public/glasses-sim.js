/* ============================================================================
   SaveVision — glasses (wearer) simulator.

   Stands in for the user-ios app so the whole product is demoable in a browser:
   - Publishes the webcam as the wearer's POV (video + audio) to the operator.
   - Creates the one-way payload channel and RENDERS what the doctor sends:
     guidance text, freehand drawings, example images, map/direction.
   - Emulates the Meta NEURAL BAND input model (swipes + index/middle pinch),
     mapped to the keyboard, driving local HUD actions (browse images, zoom a
     diagram, acknowledge, dismiss).

   Data is one-way: the wearer sends NOTHING back except the media stream.
   Neural Band input stays LOCAL to the glasses (it never goes to the doctor) —
   matching "only the doctor sends info what to do". On real glasses this whole
   layer lives in user-ios and rides Matrix.
============================================================================ */

const el = (id) => document.getElementById(id);
const pov = el("pov"), overlay = el("overlay"), banner = el("banner");
const imgcard = el("imgcard"), imgcardImg = el("imgcardImg");
const imgcardCap = el("imgcardCap"), imgcardCount = el("imgcardCount");
const compass = el("compass"), arrow = el("arrow"), lbl = el("lbl");
const fs = el("fs"), fsImg = el("fsImg"), fsCap = el("fsCap");
const ack = el("ack"), gesture = el("gesture");
const octx = overlay.getContext("2d");

let ws = null, pc = null, room = null, localStream = null;
let bannerTimer = null;

// wearer-side view state driven by the Neural Band
const images = [];          // history of { dataUrl, caption }
let imgIndex = -1;
let fullscreen = false;
let zoom = 1;

/* =====================  Neural Band input layer  =========================
   Normalised actions: up | down | left | right | enter | cancel.
   Sources: keyboard (emulator) + a 'mwa:gesture' CustomEvent + an optional
   device SDK hook — identical pattern to glasses-webapp/input.js, so the real
   band drops in without touching the action handler below. */
const NeuralBand = (() => {
  const listeners = new Set();
  const emit = (a) => listeners.forEach((fn) => fn(a));

  const KEY = {
    ArrowUp: "up", ArrowDown: "down", ArrowLeft: "left", ArrowRight: "right",
    Enter: "enter", " ": "enter", Escape: "cancel", Backspace: "cancel",
  };
  const GEST = {
    swipeUp: "up", swipeDown: "down", swipeLeft: "left", swipeRight: "right",
    pinchIndex: "enter", indexPinch: "enter", select: "enter",
    pinchMiddle: "cancel", middlePinch: "cancel", back: "cancel",
  };

  function init() {
    window.addEventListener("keydown", (e) => {
      const a = KEY[e.key];
      if (!a) return;
      e.preventDefault();
      emit(a);
    });
    window.addEventListener("mwa:gesture", (e) => {
      const a = GEST[e.detail && e.detail.name];
      if (a) emit(a);
    });
    const sdk = window.MetaWearables || window.metaWearables;
    if (sdk && typeof sdk.onGesture === "function") {
      sdk.onGesture((g) => { const a = GEST[g && (g.type || g.name)]; if (a) emit(a); });
    }
  }
  return { init, onAction: (fn) => listeners.add(fn) };
})();

const GESTURE_LABEL = {
  up: "↑ swipe up", down: "↓ swipe down", left: "← swipe left",
  right: "→ swipe right", enter: "index-pinch", cancel: "middle-pinch",
};

function flashGesture(action) {
  gesture.textContent = GESTURE_LABEL[action] || action;
  gesture.classList.add("show");
  clearTimeout(flashGesture._t);
  flashGesture._t = setTimeout(() => gesture.classList.remove("show"), 900);
}

// ---- action handler: what each Neural Band action does on the wearer's HUD ----
function onAction(action) {
  flashGesture(action);
  switch (action) {
    case "enter": // index pinch — select / acknowledge
      if (fullscreen) return closeFullscreen();
      if (banner.textContent) return acknowledge();
      if (images.length) return openFullscreen();
      break;
    case "cancel": // middle pinch — dismiss / back
      if (fullscreen) return closeFullscreen();
      return dismiss();
    case "left":  return navImage(-1);
    case "right": return navImage(1);
    case "up":    return fullscreen ? setZoom(zoom + 0.25) : openFullscreen();
    case "down":  return fullscreen ? setZoom(zoom - 0.25) : hideImageCard();
  }
}

// ---- wearer-local behaviours ----
function acknowledge() {
  ack.classList.remove("show"); void ack.offsetWidth; ack.classList.add("show");
  banner.textContent = "";
  // NOTE: stays local. A minimal "ack" signal to the doctor could be added
  // later, but the current design keeps the wearer→doctor path media-only.
}

function dismiss() {
  hideImageCard();
  octx.clearRect(0, 0, overlay.width, overlay.height);
  banner.textContent = "";
}

function navImage(dir) {
  if (!images.length) return;
  imgIndex = (imgIndex + dir + images.length) % images.length;
  renderImageCard();
  if (fullscreen) renderFullscreen();
}

function renderImageCard() {
  const it = images[imgIndex];
  if (!it) return;
  imgcardImg.src = it.dataUrl;
  imgcardCap.textContent = it.caption || "reference";
  imgcardCount.textContent = images.length > 1 ? `${imgIndex + 1}/${images.length}` : "";
  imgcard.style.display = "block";
  imgcard.classList.add("focus");
}
function hideImageCard() { imgcard.style.display = "none"; imgcard.classList.remove("focus"); }

function openFullscreen() {
  if (!images.length) return;
  fullscreen = true; zoom = 1;
  renderFullscreen();
  fs.style.display = "flex";
}
function renderFullscreen() {
  const it = images[imgIndex]; if (!it) return;
  fsImg.src = it.dataUrl;
  fsCap.textContent = (it.caption || "reference") + (images.length > 1 ? `  ·  ${imgIndex + 1}/${images.length}` : "");
  setZoom(zoom);
}
function closeFullscreen() { fullscreen = false; fs.style.display = "none"; }
function setZoom(z) { zoom = Math.max(1, Math.min(4, z)); fs.style.setProperty("--z", zoom); }

/* =====================  WebRTC / signaling (POV publish)  ================= */
async function getIceServers() {
  try { return (await (await fetch("/api/ice")).json()).iceServers; }
  catch { return [{ urls: "stun:stun.l.google.com:19302" }]; }
}
const wsUrl = () => `${location.protocol === "https:" ? "wss" : "ws"}://${location.host}`;

function fitOverlay() { overlay.width = overlay.clientWidth; overlay.height = overlay.clientHeight; }
window.addEventListener("resize", fitOverlay);

async function start() {
  fitOverlay();
  // Camera only — NO microphone prompt. Failure is non-fatal: we still open a
  // room so "Call for help" always yields a code (guidance works without POV).
  try {
    localStream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: "environment" }, audio: false });
  } catch {
    try { localStream = await navigator.mediaDevices.getUserMedia({ video: true, audio: false }); }
    catch (e) { console.warn("camera unavailable:", e.message); showBanner("Camera off — guidance still works", false); }
  }
  if (localStream) pov.srcObject = localStream;

  ws = new WebSocket(wsUrl());
  ws.onopen = () => ws.send(JSON.stringify({ type: "create" }));
  ws.onmessage = (e) => handleSignal(JSON.parse(e.data));
}

async function ensurePeer() {
  if (pc) return pc;
  pc = new RTCPeerConnection({ iceServers: await getIceServers() });
  if (localStream) localStream.getTracks().forEach((t) => pc.addTrack(t, localStream));
  const channel = pc.createDataChannel("guidance"); // wearer owns it; doctor sends, we read
  channel.onmessage = (e) => render(JSON.parse(e.data));
  pc.onicecandidate = (e) => { if (e.candidate) ws.send(JSON.stringify({ type: "candidate", candidate: e.candidate })); };
  return pc;
}

async function handleSignal(msg) {
  switch (msg.type) {
    case "room_created": room = msg.room; el("code").textContent = msg.room; break;
    case "peer_joined": {
      const peer = await ensurePeer();
      const offer = await peer.createOffer();
      await peer.setLocalDescription(offer);
      ws.send(JSON.stringify({ type: "offer", sdp: offer.sdp }));
      break;
    }
    case "room_joined": {  // we joined an operator-issued case code → publish our POV
      const peer = await ensurePeer();
      const offer = await peer.createOffer();
      await peer.setLocalDescription(offer);
      ws.send(JSON.stringify({ type: "offer", sdp: offer.sdp }));
      el("code").textContent = (el("joinCode").value || "").toUpperCase();
      break;
    }
    case "error": showBanner(msg.message, false); break;
    case "answer": if (pc) await pc.setRemoteDescription(new RTCSessionDescription(msg)); break;
    case "candidate":
      if (pc && msg.candidate) { try { await pc.addIceCandidate(new RTCIceCandidate(msg.candidate)); } catch {} }
      break;
    case "peer_left": showBanner("Operator disconnected", false); break;
  }
}

// ---- render the doctor's one-way payloads ----
function render(p) {
  switch (p.kind) {
    case "guidance": showBanner(p.text, /stop|unsafe/i.test(p.text)); break;
    case "drawing":  drawStrokes(p.strokes); break;
    case "clear":    octx.clearRect(0, 0, overlay.width, overlay.height); banner.textContent = ""; break;
    case "image":    addImage(p.dataUrl || p.url, p.caption); break;
    case "map":      showMap(p.bearing, p.label); break;
    case "livemap":  showLiveMap(p); break;   // real OSM map, toggled by operator
  }
}

// Real (OpenStreetMap) map on the glasses, turned on/off by the operator.
let hudMap = null;
function showLiveMap(p){
  const box = el("hudmap"), lbl = el("hudmapLbl");
  if(!p.on){ box.style.display="none"; lbl.style.display="none"; return; }
  box.style.display="block";
  const lat = p.lat ?? 48.2082, lng = p.lng ?? 16.3738, zoom = p.zoom ?? 16;
  if(!hudMap){
    hudMap = L.map(box, { zoomControl:false, attributionControl:true }).setView([lat,lng], zoom);
    L.tileLayer("https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png", { maxZoom:19 }).addTo(hudMap);
    hudMap._dest = L.marker([lat,lng]).addTo(hudMap);
  } else {
    hudMap.setView([lat,lng], zoom); hudMap._dest.setLatLng([lat,lng]);
  }
  setTimeout(()=>hudMap.invalidateSize(), 60);
  if(p.label){ lbl.textContent = "🧭 " + p.label; lbl.style.display="block"; } else lbl.style.display="none";
}

// Connect the glasses to an operator-issued CASE CODE (we publish our POV).
async function joinCase(code){
  code = (code||"").trim().toUpperCase();
  if(code.length!==6) return showBanner("Enter the 6-char case code", false);
  if(!localStream){
    try { localStream = await navigator.mediaDevices.getUserMedia({ video:{facingMode:"environment"}, audio:false }); pov.srcObject = localStream; }
    catch { showBanner("Camera off — connecting anyway", false); }
  }
  ws = new WebSocket(wsUrl());
  ws.onopen = () => ws.send(JSON.stringify({ type:"join", room: code }));
  ws.onmessage = (e) => handleSignal(JSON.parse(e.data));
}

function showBanner(text, danger) {
  banner.textContent = text;
  banner.classList.toggle("danger", !!danger);
  clearTimeout(bannerTimer);
  if (!danger) bannerTimer = setTimeout(() => { banner.textContent = ""; }, 12000);
}

function drawStrokes(strokes) {
  octx.clearRect(0, 0, overlay.width, overlay.height);
  for (const s of strokes) {
    octx.strokeStyle = s.color || "#00ff95";
    octx.lineWidth = 5; octx.lineCap = "round"; octx.lineJoin = "round";
    octx.beginPath();
    s.points.forEach((pt, i) => {
      const x = pt.x * overlay.width, y = pt.y * overlay.height;
      i ? octx.lineTo(x, y) : octx.moveTo(x, y);
    });
    octx.stroke();
  }
}

// New images append to history; the wearer browses with left/right.
function addImage(dataUrl, caption) {
  images.push({ dataUrl, caption });
  imgIndex = images.length - 1;
  renderImageCard();
}

function showMap(bearing, label) {
  compass.style.display = "flex";
  arrow.style.transform = `rotate(${bearing || 0}deg)`;
  lbl.textContent = label || "";
}

// ---- boot ----
NeuralBand.init();
NeuralBand.onAction(onAction);
el("startBtn").addEventListener("click", () => {
  start();
  el("startBtn").disabled = true;
  el("startBtn").textContent = "Connecting…";
  el("glasses").focus();
});
el("joinBtn").addEventListener("click", () => { joinCase(el("joinCode").value); el("glasses").focus(); });
