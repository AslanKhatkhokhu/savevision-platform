# SaveVision — How it works & development plan

SaveVision is a **remote expert-guidance platform** on smart glasses. A wearer
streams their first-person view to a remote expert who guides them with text,
drawings, images, and map directions on the heads-up display. **Medical
assistance is the first feature.** Everything rides **Matrix** (E2E-encrypted,
self-hosted). Data is **one-way: expert → wearer**; the wearer only publishes
POV + audio.

---

## 1. How it should work (end to end)

```
  WEARER (glasses + phone)                     EXPERT (doctor, web)
  ─────────────────────────                    ─────────────────────
  1. "Call for help"  ───────────────┐
  2. App joins an encrypted           │  Matrix homeserver (self-hosted)
     Matrix room, starts a            ▼  • creates/owns the room
     MatrixRTC call          ┌──────────────────┐  • routes E2E events
  3. VisionClaw captures POV │  Matrix + LiveKit │  • relays A/V (can't read)
     → published as the call │   (Element Call)  │
     video track ────────────┤                  ├──► 4. Expert is paired in,
  6. HUD renders incoming    │                  │       sees the live POV
     org.savevision.* events ◄──────────────────┤    5. Expert sends guidance:
     (text/drawing/image/map)│                  │       text · drawing · image ·
  7. Wearer uses Neural Band │                  │       map  → custom E2E events
     to browse/zoom/ack ─────┘                  └──►    (one-way)
```

**Lifecycle:** call for help → pair with on-call expert → live POV + guidance →
guidance rendered on HUD → wearer acknowledges via Neural Band → session ends /
hands off → encrypted, minimal-metadata record (or none) per policy.

**Today (this repo):** `operator-web` + `glasses-sim.html` run this exact flow
over a local WebRTC harness — identical payloads, no Matrix needed — so it's
fully demoable. Production swaps the transport to Matrix; renderers don't change.

---

## 2. Components & ownership

| Component | Stack | Owner | State |
|---|---|---|---|
| `operator-web` (expert UI) | HTML/JS → matrix-js-sdk + Element Call | budelius (web) | UI done; Matrix TODO |
| `user-ios` (wearer app) | Swift + matrix-rust-sdk + VisionClaw + Meta DAT | you (iOS) | scaffold |
| Matrix homeserver | Synapse/Dendrite/Conduit + LiveKit | colleague | exists (need URL) |
| `glasses-sim` (emulator) | HTML/JS | shared | done |
| Protocol & docs | `PROTOCOL.md`, `MATRIX.md` | shared | done |

---

## 3. Development plan (milestones)

**M0 — Demo harness (DONE).** Operator UI, glasses simulator, one-way payloads
(text/drawing/image/map), Neural Band input emulation, concept PDF.

**M1 — Matrix transport.**
- Stand up / connect to the homeserver; create a room per session.
- `operator-web`: replace WebSocket `send()` with `client.sendEvent(roomId, "org.savevision.<kind>", payload)`; embed Element Call for A/V.
- Define + document the `org.savevision.*` event schema (extend `PROTOCOL.md`).
- Power levels: only experts can send `org.savevision.*`.

**M2 — Wearer app (iOS).**
- matrix-rust-sdk: join room, render `org.savevision.*` on the HUD (port `glasses-sim.js` renderer).
- Publish camera into the MatrixRTC call (iPhone camera first).
- Neural Band input → reuse the normalized action layer.

**M3 — Glasses integration.**
- Meta Wearables DAT SDK: real POV capture + display rendering via VisionClaw.
- On-device offline fallback checklists; audio-only degradation.

**M4 — Productionization.**
- Expert auth + on-call queue + pairing (appservice/bot).
- Triage of multiple sessions; session handoff.
- Security review, metadata minimization, retention policy; IHL/medical guardrails from the concept doc enforced in UI.

**M5 — Pilot.** Field test with vetted clinicians on a closed homeserver.

---

## 4. Open decisions (need your input)

1. **Homeserver:** which implementation + base URL? (Synapse / Dendrite / Conduit)
2. **A/V:** Element Call (MatrixRTC/LiveKit) vs legacy 1:1 `m.call.*`?
3. **Pairing:** open "call for help" bot, or fixed on-call rooms?
4. **First domain scope:** medical only for the pilot, or include navigation/SAR?
5. **Hardware:** dev on the simulator only, or is a Display unit obtainable in-region?

---

## 5. What to tell me to build it right

A short guide so each request turns into correct, fast work:

- **Work one component at a time.** "Wire `operator-web` to Matrix" beats "build
  the whole system." I'll go deeper and break less.
- **Give the missing facts up front.** For Matrix work I need: homeserver URL,
  which server, an access token or test account, and the A/V choice (§4). Without
  them I build against placeholders.
- **State the goal + acceptance check.** e.g. "Doctor's drawing shows on the
  wearer HUD within 1s, over Matrix" — tells me when it's done.
- **Share secrets safely — never in the repo.** Put keys/tokens in a local
  `.env` (already git-ignored) or paste them to me directly; I'll wire them via
  env vars, not commits.
- **Say the priority when you stack requests.** If you send five asks, tell me
  which is first; otherwise I'll sequence them myself and say so.
- **"Use a workflow" for big sweeps.** For multi-file audits, migrations, or
  research-heavy docs, say the word and I'll run a multi-agent workflow.
- **Tell me the domain context.** Medical vs navigation vs SAR changes the
  guidance UI, the policy, and the wording.
- **Point me at references.** A repo (like VisionClaw), a doc URL, or a screenshot
  of the behavior you want removes guesswork.

A good request looks like:
> "In `operator-web`, replace the data-channel `send()` with Matrix events
> against `https://matrix.ourdomain` (Synapse, token in the `.env` I'll paste).
> Use Element Call for A/V. Done when the glasses-sim equivalent receives a
> drawing event E2E-encrypted. Do just this."
