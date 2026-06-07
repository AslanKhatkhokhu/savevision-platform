# Claude design prompt — add-ons (mini-map + 3D animated glasses video)

Paste these into Claude. They're written to **combine with** the first prompt
([CLAUDE_DESIGN_PROMPT.md](CLAUDE_DESIGN_PROMPT.md)) — same product, same dark
mint/cyan style, single self-contained HTML files, no libraries, no build step.

---

## Add-on 1 — Mini-map inside the operator's streaming window

> **Extend the SaveVision expert (doctor) dashboard:** inside the live POV video
> panel, add a small **mini-map overlay** pinned to the bottom-left corner
> (~190px wide, semi-transparent dark card with a 1px border, rounded). It shows
> **where the person on the call is**: a compact schematic map (sector grid, a
> couple of muted building blocks — no real map tiles), with a pulsing **red pin
> for this casualty** (labelled with the call id, e.g. C-07), a cyan **collection
> point (CCP) marker**, and a small **responder triangle**. A tiny header strip
> reads "Location · #C-07" and the sector (e.g. "Sector B-4"). Keep it glanceable
> and unobtrusive so it never covers the center of the POV. Dark, high-contrast,
> one mint/cyan accent.

---

## Add-on 2 — 3D animated glasses demo (looping product video)

> **Build a single self-contained HTML file (inline CSS + vanilla JS, no
> libraries) that plays a short looping, cinematic "product video" of the
> SaveVision glasses — pure CSS 3D, no WebGL.**
>
> **Scene:** a stylized pair of smart glasses rendered in **3D perspective**
> (CSS `transform: perspective() rotateY()`), floating on a dark gradient
> backdrop, slowly rotating back and forth (~8s ease-in-out loop). The **right
> lens** is the live HUD.
>
> **Animated guidance sequence inside the lens (loops, ~10-12s):**
> 1. A dark POV scene fades in.
> 2. An instruction **banner types in**: "Apply tourniquet — high & tight".
> 3. The doctor's **cyan arrow + circle draw themselves** onto the scene (animate
>    SVG `stroke-dashoffset` so the strokes appear to be drawn live).
> 4. A small **how-to diagram inset pops in** (a schematic tourniquet/windlass).
> 5. A **direction compass** fades in and its arrow **rotates** to a heading,
>    with a label "Collection point · 40 m".
> 6. A green **"✓ Acknowledged"** flash, then everything fades and the loop restarts.
>
> **Feel:** calm, clinical, trustworthy — not flashy. Black backgrounds (black =
> transparent on real glasses optics), one mint/cyan accent (#00e0ff / #00ff95),
> large legible type, soft glows. Add a lower-third caption that fades in:
> "SaveVision — a doctor's eyes, on your side." Make it loop seamlessly so it can
> be screen-recorded into a video. Include a small "Replay" button.
>
> **Done when:** the glasses rotate in 3D, the full guidance sequence animates and
> loops cleanly, and it's one self-contained file.

---

Reference (already in this repo if Claude wants it): `docs/mockups/mockup-operator.html`
(now includes the mini-map) and `operator-web/public/glasses-sim.js` (the real
HUD renderer + payload shapes).
