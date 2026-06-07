# SaveVision — demo film (Remotion)

The 85‑second SaveVision scenario rendered **programmatically** with [Remotion](https://remotion.dev) — no AI footage, no external assets, so it renders anywhere.

## Run
```bash
cd film
npm install            # installs remotion + react (downloads a headless Chromium on first render)
npm run studio         # live preview/editor at http://localhost:3000
npm run render         # → out/savevision.mp4  (1920×1080)
npm run render:social  # → out/savevision-vertical.mp4 (1080×1920 for social)
```

## Scenes (`src/Film.tsx`)
1. Cold open — *"An ordinary afternoon. Somewhere in Ukraine."*
2. Rider — Maksym in a Peugeot, Ray‑Ban glasses, Hello‑Kitty pop.
3. Girl — Sofiia walking, hard metal.
4. Drone — a Shahed crossing the sky to "Lasciatemi cantare…".
5. Strike — white flash → dust → *"400 m away — one person down."*
6. Guided rescue — glasses POV (operator annotation + banner + voice) ‖ operator console (map pin + ambulance ETA).
7. Ambulance — *"Care transferred."*
8. Motivational close — the 4‑min‑brain vs 10–20‑min‑ambulance line.
9. Logo.

## Notes
- **Audio** is intentionally omitted (don't ship the licensed Hello‑Kitty / "L'Italiano" tracks). Add royalty‑free stand‑ins + an ElevenLabs operator VO as `<Audio>` in the scenes, or layer them in CapCut/Resolve over the rendered MP4.
- To make scenes photoreal later, drop AI/real clips behind each scene with `<OffthreadVideo>` and keep the SaveVision UI overlays (HUD, console, captions) on top — the overlays are the convincing part and they're free.
- Edit timings in `SaveVisionFilm` (frames @30fps); total = 2550 frames ≈ 85 s.
