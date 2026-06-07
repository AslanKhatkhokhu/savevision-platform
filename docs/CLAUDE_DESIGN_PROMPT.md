# Paste-ready design request for Claude (claude.ai)

Copy everything in the box below into Claude. It will produce a single-file,
runnable web-app design as an artifact you can preview and iterate on.

---

> **Build me a web-app UI design for "SaveVision", as a single self-contained
> HTML file (inline CSS + vanilla JS, no external libraries, no build step) that
> runs as an artifact.**
>
> **Product:** SaveVision is a remote expert-guidance platform for emergencies on
> smart glasses. A wearer (no training) streams their first-person camera view to
> a remote expert (first use case: a doctor) who guides them. Data is **one-way:
> the expert sends, the wearer only receives** (the wearer publishes video only).
> The expert can send four things: **(1) instruction text**, **(2) freehand
> drawings** on the video, **(3) example images** (reference diagrams), and
> **(4) a map/direction** (a heading + label).
>
> **Build two views, switchable with a tab bar at the top:**
>
> **View A — Expert (doctor) dashboard** (desktop, ~1280×800):
> - Large left area: a live "POV" video panel (use a dark placeholder scene) with
>   a transparent canvas on top where the doctor draws freehand with the mouse.
> - A drawing toolbar under it: 4 color swatches, Freeze, Clear, "Send drawing".
> - A right panel with cards: **Instruction text** (textarea + Send + quick chips
>   incl. a red "STOP/unsafe"), **Example image** (file picker + Send), **Map /
>   direction** (label field + 4 direction buttons + Send), and a **Session log**.
>
> **View B — Glasses HUD** (the wearer's display, a 600×600 square):
> - The POV video fills the square; overlays on top: a top **instruction banner**
>   (red when the text contains "stop/unsafe"), the doctor's **freehand strokes**,
>   an **example-image inset** bottom-right, a **direction compass** bottom-left.
> - Emulate the **Meta Neural Band** input with the keyboard: **arrow keys** =
>   swipe (browse images / zoom), **Enter** = index-pinch (select/acknowledge),
>   **Esc** = middle-pinch (dismiss/back). Show a small gesture pill on each input.
>
> **Make the two views talk to each other in the artifact** (in-memory, no
> network): clicking Send in View A updates the HUD in View B live, so the whole
> flow is demoable in one file.
>
> **Visual style:** dark, high-contrast, calm and clinical — not flashy. Black
> backgrounds (on real additive glasses optics, black = transparent), a single
> bright accent (mint/cyan ~#00e0ff / #00ff95), large legible type, generous
> spacing, rounded cards. It must feel trustworthy in a life-or-death moment.
>
> **Done when:** both views render, the doctor can draw + send all four payload
> types, the HUD shows them, and the Neural Band keyboard controls work. Keep it
> one file. After it works, suggest 3 refinements.

---

Reference implementation (already in this repo, if Claude asks for it):
`operator-web/public/` (operator.js, glasses-sim.js), `PROTOCOL.md` (payload
shapes), and the mockups in `docs/mockups/`.
