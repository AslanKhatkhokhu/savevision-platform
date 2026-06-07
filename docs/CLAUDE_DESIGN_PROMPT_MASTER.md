# SaveVision — master design prompt (paste into Claude)

One complete, copy-paste brief covering all screens. Paste everything in the box.

---

> **Design and build "SaveVision" as a single self-contained HTML file (inline CSS
> + vanilla JavaScript, no external libraries, no build step) that runs as an
> artifact. It contains multiple screens switched by a top tab bar.**
>
> ## Product
> SaveVision is a remote expert-guidance platform for emergencies on smart
> glasses. A wearer (no training) streams their first-person camera view to a
> remote expert (first use case: a doctor) who guides them in real time. Medical
> is the first feature; the same system extends to evacuation, search & rescue,
> and technical guidance. **Data is one-way: the expert sends, the wearer only
> receives** (the wearer publishes video only). The expert can send four things:
> **(1) instruction text, (2) freehand drawings on the video, (3) example images
> (reference diagrams), (4) a map/direction (heading + label).**
>
> ## Global visual style
> Dark, high-contrast, calm and clinical — trustworthy in a life-or-death moment,
> never flashy. Near-black backgrounds (on real additive-display glasses, black =
> transparent), one bright accent in mint/cyan (#00ff95 / #00e0ff), severity
> colors (critical #ff4d4d, urgent #ffb020, stable #3fb950), large legible type,
> generous spacing, rounded cards, subtle borders (#2a323d). System font stack.
>
> ## Screens (top tab bar to switch)
>
> **Tab 1 — Expert dashboard (1:1 call, desktop ~1280×800).**
> - Large left POV video panel (dark placeholder scene) with a transparent canvas
>   on top where the doctor draws freehand with the mouse.
> - A **mini-map overlay** pinned bottom-left of the POV (~190px, semi-transparent
>   card): compact sector grid, a pulsing **red casualty pin** (call id e.g.
>   C-07), a cyan **CCP marker**, a small responder triangle, header "Location ·
>   #C-07 · Sector B-4". Glanceable, never covers the POV center.
> - Drawing toolbar under the video: 4 color swatches, Freeze, Clear, Send drawing.
> - Right panel cards: **Instruction text** (textarea + Send + quick chips
>   including a red "STOP / unsafe"); **Example image** (file picker + Send);
>   **Map / direction** (label field + 4 direction buttons + Send); **Session log**.
>
> **Tab 2 — Glasses HUD (the wearer's display, a 600×600 square).**
> - POV fills the square; overlays: top **instruction banner** (turns red if the
>   text contains "stop/unsafe"), the doctor's **freehand strokes**, an
>   **example-image inset** bottom-right, a **direction compass** bottom-left.
> - Emulate the **Meta Neural Band** input with the keyboard: **arrow keys** =
>   swipe (browse images / zoom a diagram), **Enter** = index-pinch
>   (select / acknowledge), **Esc** = middle-pinch (dismiss / back). Show a small
>   gesture pill on each input, and a "✓ Acknowledged" flash on index-pinch.
>
> **Tab 3 — Operations console (coordinator, desktop ~1440×900). Three columns:**
> - **Call management (left):** a queue of people calling for help. Each call card
>   has a severity stripe (critical/urgent/stable), wearer name/id, location
>   sector, short status, assigned operator, a live timer, and Join / Assign
>   buttons. Show a few examples plus header counts (live / waiting / operators).
> - **Situational map (center):** a schematic sector map (grid A–D × 1–4, muted
>   building blocks, dashed roads — no real map tiles) showing **people as
>   color-coded pins** by severity, **field responders** as triangles, and a
>   **CCP**. Include a legend.
> - **Task definer (right):** a form to assign a task to **a person OR an
>   operator** (assignee dropdown, task text, priority High/Med/Low, Assign), plus
>   a live **task list** with assignee and status chips (assigned / in progress /
>   done). Color person-tasks and operator-tasks differently.
>
> **Tab 4 — 3D animated glasses demo (looping product video, pure CSS 3D — no WebGL).**
> - A stylized pair of smart glasses in **3D perspective** (CSS `perspective()` +
>   `rotateY()`), on a dark gradient, slowly rotating back and forth (~8s loop).
>   The right lens is the HUD.
> - Looping sequence (~10–12s) inside the lens: POV fades in → banner **types in**
>   "Apply tourniquet — high & tight" → doctor's cyan arrow + circle **draw
>   themselves** (animate SVG `stroke-dashoffset`) → a **how-to diagram pops in** →
>   a **compass fades in and its arrow rotates** to a heading ("Collection point ·
>   40 m") → green **"✓ Acknowledged"** flash → fade → loop. A lower-third caption
>   fades in: "SaveVision — a doctor's eyes, on your side." Add a small "Replay"
>   button; loop seamlessly so it can be screen-recorded.
>
> ## Behavior
> Make Tabs 1 and 2 **talk to each other in-memory** (no network): clicking Send
> in the Expert dashboard updates the Glasses HUD live (text, drawing, image,
> direction), so the whole flow is demoable in one file.
>
> ## Done when
> All four tabs render and look polished; the doctor can draw + send all four
> payload types and the HUD shows them; the Neural Band keyboard controls work;
> the ops console shows call queue + map + task definer; the 3D glasses video
> animates and loops. Keep it one self-contained file. After it works, suggest 3
> refinements.
