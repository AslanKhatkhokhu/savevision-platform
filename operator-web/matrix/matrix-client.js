/* ============================================================================
   SaveVision — operator-side Matrix client (matrix-js-sdk).

   Connects the OPERATOR tool to the same Matrix room as the iOS app (which is
   attached to the glasses via VisionClaw). One room per emergency "case"; all
   guidance for that case lives in a single **Matrix thread**.

   Connection map:

     iOS app (VisionClaw → glasses POV)            operator tool (this client)
       matrix-rust-sdk                                matrix-js-sdk
            │                                               │
            └──────────────►  matrix.org room  ◄────────────┘
                 video/audio over MatrixRTC (Element Call)
                 guidance/drawing/image/map/livemap as THREADED events
                   org.savevision.*  (E2E encrypted)

   Setup (free — matrix.org costs nothing):
     cd operator-web && npm i matrix-js-sdk
     provide HOMESERVER + ACCESS TOKEN + USER ID (see ./config.example.json)

   This file is the integration layer; it runs once matrix-js-sdk is installed
   and a token is supplied. See ../../MATRIX_CONNECTION.md.
============================================================================ */

import * as sdk from "matrix-js-sdk";

const EVENT = {
  guidance: "org.savevision.guidance",
  drawing:  "org.savevision.drawing",
  image:    "org.savevision.image",
  map:      "org.savevision.map",
  livemap:  "org.savevision.livemap",
  clear:    "org.savevision.clear",
  caseRoot: "org.savevision.case",     // the thread root event for a case
};

export class SaveVisionMatrix {
  constructor({ homeserverUrl, accessToken, userId, elementCallUrl }) {
    this.elementCallUrl = elementCallUrl || "https://call.element.io";
    this.client = sdk.createClient({ baseUrl: homeserverUrl, accessToken, userId });
  }

  async start() {
    await this.client.startClient({ initialSyncLimit: 20 });
    await new Promise((res) => this.client.once("sync", (s) => s === "PREPARED" && res()));
    return this;
  }

  /** Open (create or join) the encrypted room for a case and post the thread root. */
  async openCase(caseInfo) {
    // Create an encrypted room for this emergency. (Reuse caseInfo.roomId if set.)
    let roomId = caseInfo.roomId;
    if (!roomId) {
      const r = await this.client.createRoom({
        name: `SaveVision ${caseInfo.id} — ${caseInfo.name || "case"}`,
        visibility: "private",
        initial_state: [{ type: "m.room.encryption", state_key: "", content: { algorithm: "m.megolm.v1.aes-sha2" } }],
        invite: caseInfo.invite || [],   // e.g. the wearer's matrix user id
      });
      roomId = r.room_id;
    }
    // Root event of the case thread — all guidance threads under this.
    const root = await this.client.sendEvent(roomId, EVENT.caseRoot, {
      id: caseInfo.id, name: caseInfo.name, injury: caseInfo.injury, sev: caseInfo.sev,
      address: caseInfo.address, situation: caseInfo.situation, danger: caseInfo.danger,
    });
    return { roomId, rootEventId: root.event_id };
  }

  /** Send a doctor→wearer guidance payload as a THREADED reply under the case root. */
  async sendGuidance(roomId, rootEventId, kind, payload) {
    const type = EVENT[kind] || EVENT.guidance;
    return this.client.sendEvent(roomId, type, {
      ...payload,
      "m.relates_to": { rel_type: "m.thread", event_id: rootEventId, is_falling_back: true },
    });
  }

  /** Listen for everything in a case thread (the wearer's app sends nothing here;
      this is mainly so multiple operators see the same thread). */
  onThreadEvent(roomId, rootEventId, cb) {
    this.client.on("Event.decrypted", (ev) => handle(ev));
    this.client.on("event", (ev) => handle(ev));
    function handle(ev) {
      if (ev.getRoomId() !== roomId) return;
      const rel = ev.getContent()["m.relates_to"];
      if (rel && rel.event_id === rootEventId && rel.rel_type === "m.thread") {
        cb({ type: ev.getType(), content: ev.getContent(), sender: ev.getSender() });
      }
    }
  }

  /** Video/audio: the glasses POV rides MatrixRTC. Easiest integration is to
      embed Element Call for this room in an iframe (it handles the SFU + E2E). */
  callWidgetUrl(roomId) {
    const u = new URL(this.elementCallUrl);
    u.searchParams.set("roomId", roomId);
    u.searchParams.set("embed", "true");
    return u.toString();   // put this in an <iframe allow="camera;microphone">
  }
}

export { EVENT };
