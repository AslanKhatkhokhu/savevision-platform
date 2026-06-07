# SaveVision — everything in one place

Remote **expert-guidance platform** on smart glasses. A wearer streams their POV
to a remote expert (first feature: a **doctor**) who guides them with text,
drawings, images, and map directions on the heads-up display. One-way (expert →
wearer). Secure transport over **Matrix** (E2E, self-hosted). Medical is the
first feature; the same pipeline extends to evacuation, SAR, technical guidance.

Repo: **https://github.com/AslanKhatkhokhu/SaveVision**

## 1. Runnable code
| Path | What | Run |
|---|---|---|
| [operator-web/](../operator-web/) | Doctor interface + signaling server + **glasses emulator** | `cd operator-web && npm install && npm start` → http://localhost:8080 |
| [operator-web/public/glasses-sim.html](../operator-web/public/glasses-sim.html) | **Web-glasses emulator** — POV publish + HUD render + Neural Band keyboard input | open `localhost:8080/glasses-sim.html` |
| [user-ios/](../user-ios/) | SwiftUI wearer app (scaffold) | open in Xcode |
| [glasses-webapp/](../glasses-webapp/) | Ray-Ban Display Web App starter (600×600 HUD) | `python3 -m http.server` |

**Demo in two tabs:** glasses-sim.html (Call for help → code) + localhost:8080 (Join with code). Draw / send text / image / direction → shows on the HUD. Drive the HUD with arrows + Enter + Esc.

## 2. Architecture & process docs
| Doc | What |
|---|---|
| [MATRIX.md](../MATRIX.md) | Secure transport: video + data over E2E Matrix; integration with your homeserver |
| [PROTOCOL.md](../PROTOCOL.md) | Wire contract — one-way payloads (text/drawing/image/map) + signaling |
| [DEVELOPMENT_PLAN.md](DEVELOPMENT_PLAN.md) | How it works, milestones M0–M5, "what to tell Claude to build it right" |
| [DIVISION_OF_WORK.md](../DIVISION_OF_WORK.md) | Who builds what (you / budelius / colleague) |

## 3. Concept document (PDF)
| File | What |
|---|---|
| [SaveVision-War-Medical-Concept.pdf](SaveVision-War-Medical-Concept.pdf) | 26-page concept: war story, MARCH-based guided care, comms policy, use cases, limits, glossary |

## 4. Mockups (open the HTML directly)
| File | Screen |
|---|---|
| [mockups/mockup-operator.html](mockups/mockup-operator.html) | Doctor 1:1 dashboard + **mini-map** in the streaming window |
| [mockups/mockup-glasses.html](mockups/mockup-glasses.html) | Wearer 600×600 HUD |
| [mockups/mockup-ops-console.html](mockups/mockup-ops-console.html) | **Operations console** — call management + situational map + task definer |

## 5. Claude design prompts (paste into claude.ai)
| File | Use |
|---|---|
| [CLAUDE_DESIGN_PROMPT_MASTER.md](CLAUDE_DESIGN_PROMPT_MASTER.md) | **One paste = all four screens** (dashboard+mini-map, HUD+Neural Band, ops console, 3D glasses video) |
| [CLAUDE_DESIGN_PROMPT.md](CLAUDE_DESIGN_PROMPT.md) | First brief (dashboard + HUD) |
| [CLAUDE_DESIGN_PROMPT_2.md](CLAUDE_DESIGN_PROMPT_2.md) | Add-ons (mini-map, 3D animated glasses video) |

## Open decisions (to start Matrix integration)
1. Homeserver: Synapse / Dendrite / Conduit + URL?
2. A/V: Element Call (MatrixRTC) vs legacy `m.call.*`?
3. Pairing: "call for help" bot vs fixed on-call rooms?
