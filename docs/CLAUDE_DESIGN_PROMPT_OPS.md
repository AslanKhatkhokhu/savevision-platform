# Claude design prompt — Operations Console (coordinator screen)

Paste the box into Claude. Same product + dark mint/cyan style as the other
SaveVision screens; one self-contained HTML file.

---

> **Build the "SaveVision — Operations Console" as a single self-contained HTML
> file (inline CSS + vanilla JavaScript, no external libraries, no build step)
> that runs as an artifact. Desktop layout ~1440×900.**
>
> **Context:** SaveVision is a remote expert-guidance platform for emergencies on
> smart glasses. The Operations Console is the **coordinator's view** that sits
> above the 1:1 calls — it triages who needs help, where they are, and who is
> handling what.
>
> **Top bar:** "SaveVision · Operations Console" on the left; on the right, live
> status chips: "● 3 live", "● 2 waiting", "Operators online: 4", "People in
> field: 11", and the current sector.
>
> **Three columns:**
>
> **1) Call management (left, ~340px).** A scrollable list of call cards. Each
> card: a colored left stripe by severity (critical #ff4d4d / urgent #ffb020 /
> stable #3fb950), a monospace call id (e.g. #C-07), a severity pill, the wearer
> name or anon id + injury ("Yusuf K. — leg hemorrhage"), the location sector
> ("Sector B-4"), a short status ("tourniquet applied"), the assigned operator in
> cyan ("▷ Dr. Lena") or "unassigned" in amber, a live mm:ss timer, and a Join or
> Assign button. Show ~4 example cards across severities.
>
> **2) Situational map (center, flexible).** A schematic sector map — DO NOT use
> real map tiles. Draw with SVG: a sector grid labelled A–D × 1–4, a few muted
> building blocks, dashed roads. Plot **people as pins color-coded by severity**
> (with the call id as a small label; the critical one gently pulses), **field
> responders as cyan triangles** (R1, R2), and a **casualty collection point
> (CCP)** as a cyan "H" marker. A small legend overlay maps colors → meaning.
>
> **3) Task definer (right, ~360px).** A form to **assign a task to a person OR an
> operator**: an assignee dropdown (mixing people "Yusuf K. (person · #C-07)" and
> operators "Dr. Adan (operator)"), a task text field, a priority segmented
> control (High / Medium / Low), and an Assign button. Below it, a live **task
> list**: each item shows the task text, a status chip (ASSIGNED amber / IN
> PROGRESS cyan / DONE green), and the assignee — color person-assignees and
> operator-assignees differently. Show ~5 example tasks.
>
> **Interactivity (in-memory, no network):** clicking a call card selects it
> (highlight) and centers/flags its pin on the map; submitting the task form
> prepends a new task to the list. Keep it all in one file.
>
> **Style:** dark, high-contrast, calm and operational — like a clean dispatch
> console, not a game. Near-black background (#0d1117), panels (#161b22), subtle
> borders (#2a323d), one mint/cyan accent (#00c98d / #00e0ff), the severity
> colors above, system font, monospace for ids/timers, rounded cards.
>
> **Done when:** the three columns render and look polished, the map shows
> color-coded people + responders + CCP + legend, selecting a call highlights its
> map pin, and adding a task updates the list. One self-contained file. Then
> suggest 3 refinements.

---

Reference (already in this repo): `docs/mockups/mockup-ops-console.html` — open it
to see the intended layout and colors; ask Claude to match and improve on it.
