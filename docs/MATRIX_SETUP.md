# Connecting SaveVision to a Matrix server — what to do

SaveVision uses **Matrix** as its secure transport (E2E, self-hosted). You have
two ways to get a homeserver; pick one, then run the connection test.

---

## What you need (ask your colleague)

1. **Homeserver base URL** — e.g. `https://matrix.yourdomain` (the thing clients connect to).
2. **A test account** — a username + password, **or** an access token. (Two accounts is better: one "doctor", one "wearer".)
3. *(For video, later)* the **Element Call / LiveKit URL** — e.g. `https://call.yourdomain`.

---

## Path A — use your colleague's existing homeserver (recommended)

You already have one. Just point the test at it.

```bash
cd operator-web/matrix
HS=https://matrix.yourdomain USER_ID=svc-doctor PASS='the-password' node connection-test.mjs
```

A green run proves: **auth works, you can create a session room, and you can
send + read SaveVision events** (`org.savevision.guidance`). That's the whole
integration core. (Or copy `config.example.json` → `config.json`, fill it in, and
just run `node connection-test.mjs`.)

---

## Path B — run a local dev homeserver (no Docker needed)

If you want your own for development. Two easy options on this Mac:

**Synapse (Python — you have Python 3.13):**
```bash
pipx install matrix-synapse        # or: python3 -m pip install --user matrix-synapse
python3 -m synapse.app.homeserver \
  --server-name localhost --config-path homeserver.yaml --generate-config \
  --report-stats=no
python3 -m synapse.app.homeserver --config-path homeserver.yaml   # runs on :8008
# register a user:
register_new_matrix_user -c homeserver.yaml http://localhost:8008
```
Then: `HS=http://localhost:8008 USER_ID=<you> PASS=<pass> node connection-test.mjs`

**conduwuit (single Rust binary, lightest):** download a release binary from the
conduwuit project, set a minimal config with `server_name`, run it, register a
user, point the test at its URL.

---

## After the test passes — wiring the apps

1. **operator-web → matrix-js-sdk + Element Call**
   - `npm i matrix-js-sdk`, log in, create/join the session room.
   - Replace the data-channel `send()` with `client.sendEvent(roomId, "org.savevision.<kind>", payload)` (same payload shapes as today).
   - Embed **Element Call** for the A/V (video over Matrix).
2. **user-ios → matrix-rust-sdk**
   - Join the room, render `org.savevision.*` events on the HUD, publish the camera into the MatrixRTC call.
3. **E2E encryption** — enable encryption on the room; the SDKs handle Olm/Megolm. (The dependency-free test above is plaintext just to validate connectivity; real sessions are encrypted.)
4. **Power levels** — only operators may send `org.savevision.*`.

See [../MATRIX.md](../MATRIX.md) for the full event model and integration points.

---

## What I need from you to do this for you

Give me the **homeserver URL** + a **test account (or token)** (paste the token
directly — don't commit it; it goes in the git-ignored `config.json`/`.env`).
With that I'll: run the connection test, then wire `operator-web` to send guidance
over Matrix and add Element Call for the video.
