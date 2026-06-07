# Ray-Ban Display — Web App Starter

A zero-build HTML/CSS/JS starter for **Meta Ray-Ban Display** glasses (Wearables
Device Access Toolkit — Web Apps path). Runs in any browser; emulate the glasses
in Chrome DevTools at **600 × 600**.

## Run it

No build step. Serve the folder over HTTP (sensors/`localStorage` behave best
over a real origin):

```bash
cd "rayban-display-app"
python3 -m http.server 8080
# open http://localhost:8080
```

## Emulate the glasses display

1. Open **Chrome DevTools** (`Cmd/Ctrl+Shift+I`).
2. Toggle the **device toolbar** (`Cmd/Ctrl+Shift+M`).
3. Add a **custom device sized 600 × 600** and select it.
4. Drive the UI with the keyboard (mouse-free, like the glasses):

| Action            | Keyboard         | Real glasses (Neural Band) |
| ----------------- | ---------------- | -------------------------- |
| Navigate          | Arrow keys ↑↓←→  | Swipe up/down/left/right   |
| Select / enter    | `Enter` / `Space`| Index-finger pinch         |
| Cancel / back     | `Esc` / `Backspace` | Middle-finger pinch     |

Meta's rule of thumb: if it works on desktop with arrows + Enter, it works on
the glasses.

## SaveVision HUD screen

Open `savevision.html` for the actual SaveVision glasses HUD. It renders the
same message/image/location/map payloads as the iOS virtual overlay.

```bash
python3 -m http.server 8081
# dev bridge preview
open 'http://localhost:8081/savevision.html'
# backend-connected preview
open 'http://localhost:8081/savevision.html?api=http://localhost:8080&caseId=C-10'
```

Inputs:

- Backend live case stream: `?api=http://host:8080&caseId=C-10`
- Dev bridge: `BroadcastChannel('savevision-hud').postMessage({kind:'guidance', text:'Apply pressure'})`
- Dev bridge: `localStorage.setItem('savevision.hud', JSON.stringify(payload))`

## Architecture

```
index.html          600x600 starter stage + hint bar
savevision.html     SaveVision HUD renderer for messages/images/locations/maps
styles.css          high-contrast starter HUD theme
savevision.css      SaveVision overlay HUD theme
input.js            Input layer → normalized actions: up|down|left|right|enter|cancel
screens.js          Screens (home, clock, counter, compass, about) + list helper
app.js              Screen router with a back-stack
```

### Adding a screen

1. Define `{ render(ctx), onAction(action, ctx), teardown? }` in `screens.js`.
2. Register it in the `SCREENS` map.
3. Navigate to it with `ctx.navigate('yourName')`.

`ctx` gives you `navigate`, `back`, `toast`, `setHint`, and `params`.

## Going to real hardware

The only device-specific glue lives in **`input.js → attachDeviceGestures()`**.
When you have developer-preview access and the official Neural Band JS hook,
wire it there — every screen keeps working unchanged because they only ever see
the six normalized actions.

Capabilities you can use from a Web App (per Meta docs): Neural Band gestures,
captouch, motion/orientation sensors, phone GPS, local storage. During Meta's
preview, publishing is limited — share via password-protected URL / release
channels (≤100 testers).

## Docs

- Web Apps: https://wearables.developer.meta.com/docs/develop/webapps
- Testing: https://wearables.developer.meta.com/docs/develop/webapps/test/
- Starter kit: https://github.com/facebookincubator/meta-wearables-webapp
