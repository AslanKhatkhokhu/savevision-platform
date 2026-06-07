# AI guidance pipeline (with operator approval)

A server turns the wearer's live view into a **procedure-specific instruction
image** ("how to bandage *this* injury"), which the **operator must approve**
before it reaches the wearer. The operator stays in control of everything the
wearer sees — consistent with SaveVision's safety model.

```
 glasses video ─▶ Generation server ─▶ proposed guidance image ─▶ OPERATOR review
   (POV frames)     1) scene/3D understanding                         │ approve / edit / discard
                    2) injury analysis                                 ▼
                    3) generate procedure image            approved image ─▶ wearer HUD
                                                            (org.savevision.image, E2E)
```

## Stages

1. **Capture** — the wearer's POV frames arrive on the operator side (over the
   MatrixRTC call / WebRTC).
2. **Scene & 3D understanding** — the server reconstructs the scene (depth / 3D)
   and localises the injury region in the frame. (Models: monocular depth +
   segmentation; e.g. a depth estimator + a wound/anatomy segmenter.)
3. **Injury analysis** — classify the injury type and the body region (e.g.
   "forearm laceration, arterial bleeding") to choose the correct procedure.
4. **Generate guidance with Claude (vision)** — send the POV frame to **Claude**
   (Anthropic API, vision input). Claude analyses the injury in the actual image
   and returns structured guidance: the injury assessment, ordered steps, and an
   **SVG annotation overlay** (arrows/markers drawn at normalised coordinates on
   the limb) — which renders directly on the HUD. Claude is text+vision (it does
   not output raster images), so it produces the *annotation + instructions* over
   the real frame; for a fully rendered raster procedure image you'd add a
   separate image model. Claude vision is the better core here because it reasons
   about the specific scene rather than drawing a generic picture.
5. **Operator approval (gate)** — the proposal is shown ONLY to the operator with
   **Approve & send / Edit / Discard**. Nothing reaches the wearer without it.
6. **Deliver** — on approval, the image is sent to the wearer as an
   `org.savevision.image` event (E2E over Matrix) and rendered on the HUD.

## Why the approval gate matters

- **Safety**: a generative model can be wrong; a licensed clinician vets every
  image before a frightened bystander acts on it.
- **Scope/IHL**: keeps a human clinician responsible for all guidance.
- **Trust**: the wearer only ever sees clinician-approved content.

## Implementation notes

- **Where it runs**: a generation service (own GPU or hosted) behind the
  operator app. The operator app calls it (`POST /api/guidance` with the current
  frame + injury hint) and shows the returned image in the approval panel.
- **Guidance backend = Claude (vision).** `POST /api/guidance` sends the captured
  frame to the Anthropic API; Claude returns JSON: `{ assessment, steps[],
  annotation_svg, banner }`. The operator app renders that in the approval panel.
  Use the latest Claude model with vision; force JSON via a tool/structured
  output. **Cost**: paid per token, billed only when the operator clicks
  "Generate" (one frame on demand, not per video second) — so it's small and
  controllable. A self-hosted vision model avoids per-call API cost.
  (Optionally add a separate image model for a fully rendered raster overlay.)
- **3D**: monocular depth (e.g. Depth-Anything) gives a 3D sense from the single
  glasses camera; a second camera or motion gives true depth.
- **Privacy/security**: run the generation server **in-house** (no third-party
  cloud) so casualty imagery never leaves your infrastructure — consistent with
  the Matrix self-hosting choice.

## Prototype in this repo

The operator UI has an **AI guidance — propose & approve** panel:
**🧠 Generate guidance** → a proposed image appears → **✓ Approve & send** pushes
it to the wearer's HUD, **✕ Discard** drops it. Today it proposes a stand-in
reference image; wiring `POST /api/guidance` to a real generator (per the stages
above) is the only change needed to make it injury-specific.
