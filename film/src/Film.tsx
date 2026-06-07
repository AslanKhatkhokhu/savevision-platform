import React from "react";
import {
  AbsoluteFill,
  Series,
  useCurrentFrame,
  useVideoConfig,
  interpolate,
  spring,
  Sequence,
} from "remotion";

/* ============================================================================
   SaveVision — 85s demo film (motion graphics, no external footage).
   Scenario: ordinary life lulled by music → a Shahed strike → a bystander,
   guided by a remote doctor on smart glasses, keeps the casualty alive until
   the ambulance arrives → motivational close.
   Renders out of the box: `npm i && npx remotion studio`.
============================================================================ */

const CYAN = "#00e0ff";
const ACCENT = "#00c98d";
const DANGER = "#ff4d4d";

// fade helper: opacity 0→1 over `inF`, hold, 1→0 over last `outF`
const useFade = (dur: number, inF = 18, outF = 18) => {
  const f = useCurrentFrame();
  return interpolate(f, [0, inF, dur - outF, dur], [0, 1, 1, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
};

const Caption: React.FC<{ children: React.ReactNode; sub?: boolean; bottom?: number }> = ({
  children,
  sub,
  bottom = 90,
}) => (
  <div
    style={{
      position: "absolute",
      bottom,
      width: "100%",
      textAlign: "center",
      color: "#fff",
      fontFamily: "Helvetica, Arial, sans-serif",
      fontWeight: sub ? 500 : 800,
      fontSize: sub ? 34 : 52,
      textShadow: "0 2px 18px #000",
      padding: "0 8%",
    }}
  >
    {children}
  </div>
);

const MusicNote: React.FC<{ label: string; color: string; x: string; y: string }> = ({
  label,
  color,
  x,
  y,
}) => {
  const f = useCurrentFrame();
  const float = Math.sin(f / 8) * 10;
  return (
    <div
      style={{
        position: "absolute",
        left: x,
        top: y,
        transform: `translateY(${float}px)`,
        color,
        fontSize: 40,
        fontWeight: 700,
        textShadow: "0 2px 10px #000",
        fontFamily: "Helvetica, Arial",
      }}
    >
      ♪ {label}
    </div>
  );
};

/* ---------------- Scene 1 — cold open ---------------- */
const ColdOpen: React.FC<{ dur: number }> = ({ dur }) => {
  const o = useFade(dur, 24, 24);
  return (
    <AbsoluteFill style={{ background: "#05070a", justifyContent: "center", alignItems: "center" }}>
      <div
        style={{
          opacity: o,
          color: "#eafff5",
          fontFamily: "Helvetica, Arial",
          fontSize: 46,
          fontWeight: 600,
          letterSpacing: 1,
          textAlign: "center",
        }}
      >
        An ordinary afternoon.
        <br />
        <span style={{ opacity: 0.7, fontSize: 34 }}>Somewhere in Ukraine.</span>
      </div>
    </AbsoluteFill>
  );
};

/* ---------------- Scene 2 — the rider (Peugeot + Hello Kitty) ---------------- */
const Rider: React.FC<{ dur: number }> = ({ dur }) => {
  const f = useCurrentFrame();
  const o = useFade(dur);
  const carX = interpolate(f, [0, dur], [-300, 1600]);
  return (
    <AbsoluteFill
      style={{
        opacity: o,
        background: "linear-gradient(180deg,#bfe3ff 0%,#dff0ff 55%,#7d7f86 55%,#5a5c63 100%)",
      }}
    >
      {/* sun */}
      <div style={{ position: "absolute", top: 70, right: 180, width: 120, height: 120, borderRadius: "50%", background: "#fff3b0", filter: "blur(2px)" }} />
      {/* small Peugeot */}
      <div style={{ position: "absolute", top: 640, left: carX }}>
        <div style={{ width: 280, height: 90, background: "#c0392b", borderRadius: "40px 60px 18px 18px", position: "relative", boxShadow: "0 10px 20px #0006" }}>
          <div style={{ position: "absolute", top: -42, left: 70, width: 130, height: 60, background: "#922b21", borderRadius: "30px 30px 0 0" }} />
          <div style={{ position: "absolute", bottom: -22, left: 36, width: 46, height: 46, borderRadius: "50%", background: "#111", border: "6px solid #444" }} />
          <div style={{ position: "absolute", bottom: -22, right: 36, width: 46, height: 46, borderRadius: "50%", background: "#111", border: "6px solid #444" }} />
        </div>
      </div>
      {/* glasses chip */}
      <div style={{ position: "absolute", top: 70, left: 90, background: "#000a", color: CYAN, padding: "8px 16px", borderRadius: 999, fontFamily: "Helvetica", fontSize: 26, border: `1px solid ${CYAN}` }}>
        👓 Ray-Ban Display · connected
      </div>
      <MusicNote label="Hello Kitty pop" color="#ff5fa2" x="58%" y="120px" />
      <Caption sub>Maksym, 28 — on his way home</Caption>
    </AbsoluteFill>
  );
};

/* ---------------- Scene 3 — the girl (metal) ---------------- */
const Girl: React.FC<{ dur: number }> = ({ dur }) => {
  const f = useCurrentFrame();
  const o = useFade(dur);
  const walk = interpolate(f, [0, dur], [200, 1400]);
  const bob = Math.abs(Math.sin(f / 6)) * 12;
  return (
    <AbsoluteFill style={{ opacity: o, background: "linear-gradient(180deg,#aebfcf,#8a97a6 60%,#4c5460 60%,#2c313a 100%)" }}>
      <Caption sub bottom={undefined as never}>{null}</Caption>
      {/* buildings */}
      {[0, 1, 2, 3, 4].map((i) => (
        <div key={i} style={{ position: "absolute", bottom: 360, left: i * 400, width: 300, height: 260 + i * 30, background: i % 2 ? "#5b6470" : "#6b7480" }} />
      ))}
      {/* walking figure */}
      <div style={{ position: "absolute", bottom: 200, left: walk, transform: `translateY(${-bob}px)` }}>
        <div style={{ width: 50, height: 50, borderRadius: "50%", background: "#2b2f36" }} />
        <div style={{ width: 60, height: 120, background: "#1f2329", borderRadius: 16, marginTop: 4 }} />
      </div>
      <MusicNote label="hard metal" color="#ff4d4d" x="40%" y="140px" />
      <Caption sub>Sofiia, 19</Caption>
    </AbsoluteFill>
  );
};

/* ---------------- Scene 4 — the drone ---------------- */
const Drone: React.FC<{ dur: number }> = ({ dur }) => {
  const f = useCurrentFrame();
  const o = useFade(dur, 18, 6);
  const x = interpolate(f, [0, dur], [-200, 1700]);
  const dread = interpolate(f, [dur * 0.5, dur], [0, 0.55], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  return (
    <AbsoluteFill style={{ opacity: o, background: "linear-gradient(180deg,#9fb8cf,#6f8196 70%,#3a4350 100%)" }}>
      <AbsoluteFill style={{ background: "#3a0d0d", opacity: dread }} />
      {/* shahed silhouette: a dark triangle/delta */}
      <div style={{ position: "absolute", top: 220, left: x }}>
        <svg width="220" height="90" viewBox="0 0 220 90">
          <polygon points="0,45 200,15 200,75" fill="#11151b" />
          <rect x="120" y="35" width="90" height="20" fill="#11151b" />
          <polygon points="150,38 175,5 185,38" fill="#11151b" />
        </svg>
      </div>
      <MusicNote label="“Lasciatemi cantare…”" color="#ffd24d" x="50%" y="120px" />
      <Caption sub>A sound in the sky no one wants to hear.</Caption>
    </AbsoluteFill>
  );
};

/* ---------------- Scene 5 — the strike ---------------- */
const Strike: React.FC<{ dur: number }> = ({ dur }) => {
  const f = useCurrentFrame();
  const flash = interpolate(f, [0, 6, 28], [0, 1, 0], { extrapolateRight: "clamp" });
  const dust = interpolate(f, [10, dur], [0, 0.8], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  const txt = interpolate(f, [40, 60, dur - 10, dur], [0, 1, 1, 0], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  return (
    <AbsoluteFill style={{ background: "#0b0b0c" }}>
      <AbsoluteFill style={{ background: `radial-gradient(circle at 50% 60%, #6b5b4a ${dust * 100}%, #18140f)`, opacity: dust }} />
      <AbsoluteFill style={{ background: "#fff", opacity: flash }} />
      <Caption bottom={130}>
        <span style={{ opacity: txt, color: DANGER }}>400 metres away — one person down.</span>
      </Caption>
    </AbsoluteFill>
  );
};

/* ---------------- Scene 6 — guided rescue (the product) ---------------- */
const Rescue: React.FC<{ dur: number }> = ({ dur }) => {
  const f = useCurrentFrame();
  const o = useFade(dur, 18, 18);
  const { fps } = useVideoConfig();
  const arrow = spring({ frame: f - 40, fps, config: { damping: 14 } });
  const ambX = interpolate(f, [0, dur], [60, 360]);
  const banner = interpolate(f, [60, 80], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
  return (
    <AbsoluteFill style={{ opacity: o, background: "#05070a", flexDirection: "row" }}>
      {/* LEFT: glasses POV */}
      <div style={{ flex: 1.4, position: "relative", background: "radial-gradient(120% 90% at 50% 120%,#20312b,#0c100e 60%)", borderRight: "2px solid #1a2330" }}>
        <div style={{ position: "absolute", top: 26, left: 26, background: "#000a", color: CYAN, border: `1px solid ${CYAN}`, padding: "6px 14px", borderRadius: 999, fontFamily: "Helvetica", fontSize: 24 }}>👓 Glasses POV · live</div>
        <div style={{ position: "absolute", top: 26, right: 26, color: "#ff7a7a", fontFamily: "Helvetica", fontSize: 22 }}>● REC</div>
        {/* casualty */}
        <div style={{ position: "absolute", left: "22%", bottom: "16%", width: "56%", height: "34%", background: "radial-gradient(60% 80% at 40% 50%,#3a4750,#232b30)", borderRadius: "50% 50% 45% 45%/60% 60% 40% 40%", opacity: 0.85 }} />
        {/* operator annotation: circle + arrow on the wound */}
        <svg style={{ position: "absolute", inset: 0 }} viewBox="0 0 100 100" preserveAspectRatio="none">
          <ellipse cx="49" cy="60" rx="8" ry="10" fill="none" stroke={CYAN} strokeWidth="0.7" opacity={arrow} />
          <path d="M26 34 Q40 48 45 55" fill="none" stroke={CYAN} strokeWidth="0.7" strokeLinecap="round" opacity={arrow} />
        </svg>
        {/* HUD banner */}
        <div style={{ position: "absolute", top: 70, left: 26, right: 26, color: ACCENT, fontFamily: "Helvetica", fontWeight: 800, fontSize: 40, opacity: banner, textShadow: "0 1px 6px #000" }}>
          Apply firm pressure — now
        </div>
        <div style={{ position: "absolute", bottom: 24, left: "50%", transform: "translateX(-50%)", background: "#000b", border: `1px solid ${CYAN}`, color: CYAN, padding: "6px 16px", borderRadius: 999, fontFamily: "Helvetica", fontSize: 22 }}>
          🔊 “Both hands. Push hard. Help is 2 minutes out.”
        </div>
      </div>
      {/* RIGHT: operator console */}
      <div style={{ flex: 1, position: "relative", background: "#0d1117" }}>
        <div style={{ position: "absolute", top: 22, left: 22, color: "#e6edf3", fontFamily: "Helvetica", fontWeight: 700, fontSize: 26 }}>SaveVision · Operations</div>
        {/* mini map */}
        <div style={{ position: "absolute", top: 80, left: 22, right: 22, bottom: 120, background: "#0a0e13", borderRadius: 14, border: "1px solid #2a323d", overflow: "hidden" }}>
          {[...Array(8)].map((_, i) => (
            <div key={i} style={{ position: "absolute", top: i * 60, left: 0, right: 0, height: 1, background: "#1c2530" }} />
          ))}
          {[...Array(10)].map((_, i) => (
            <div key={i} style={{ position: "absolute", left: i * 60, top: 0, bottom: 0, width: 1, background: "#1c2530" }} />
          ))}
          {/* casualty pin */}
          <div style={{ position: "absolute", left: "60%", top: "45%", width: 18, height: 18, borderRadius: "50%", background: DANGER, boxShadow: `0 0 0 ${6 + Math.sin(f / 6) * 4}px #ff4d4d33` }} />
          {/* ambulance moving toward it */}
          <div style={{ position: "absolute", left: ambX, top: 320, fontSize: 34 }}>🚑</div>
        </div>
        <div style={{ position: "absolute", bottom: 60, left: 22, color: ACCENT, fontFamily: "Helvetica", fontSize: 24 }}>● live POV · guiding · ETA 2:00</div>
      </div>
      <Caption sub>A bystander with no training. A doctor seeing through his eyes.</Caption>
    </AbsoluteFill>
  );
};

/* ---------------- Scene 7 — the ambulance ---------------- */
const Ambulance: React.FC<{ dur: number }> = ({ dur }) => {
  const f = useCurrentFrame();
  const o = useFade(dur);
  const x = interpolate(f, [0, 70], [1700, 760], { extrapolateRight: "clamp" });
  const beat = 0.5 + 0.5 * Math.abs(Math.sin(f / 5));
  return (
    <AbsoluteFill style={{ opacity: o, background: "linear-gradient(180deg,#243447,#10161f 60%,#0a0e13 100%)" }}>
      <div style={{ position: "absolute", top: 520, left: x }}>
        <div style={{ width: 360, height: 150, background: "#f3f5f7", borderRadius: 16, position: "relative", boxShadow: "0 14px 30px #0008" }}>
          <div style={{ position: "absolute", top: 20, left: 24, color: DANGER, fontWeight: 900, fontSize: 40, fontFamily: "Helvetica" }}>🚑</div>
          <div style={{ position: "absolute", top: 28, right: 30, color: DANGER, fontWeight: 900, fontSize: 30, fontFamily: "Helvetica" }}>AMBULANCE</div>
          <div style={{ position: "absolute", top: -22, left: 150, width: 50, height: 22, borderRadius: 6, background: `rgba(0,224,255,${beat})` }} />
          <div style={{ position: "absolute", bottom: -22, left: 60, width: 50, height: 50, borderRadius: "50%", background: "#111", border: "7px solid #555" }} />
          <div style={{ position: "absolute", bottom: -22, right: 60, width: 50, height: 50, borderRadius: "50%", background: "#111", border: "7px solid #555" }} />
        </div>
      </div>
      <div style={{ position: "absolute", top: 80, left: "50%", transform: "translateX(-50%)", background: "#000a", border: `1px solid ${ACCENT}`, color: ACCENT, padding: "8px 18px", borderRadius: 999, fontFamily: "Helvetica", fontSize: 26 }}>
        ✓ Care transferred · stand down
      </div>
      <Caption sub>He kept the brain alive until help arrived.</Caption>
    </AbsoluteFill>
  );
};

/* ---------------- Scene 8 — motivational close ---------------- */
const Close: React.FC<{ dur: number }> = ({ dur }) => {
  const f = useCurrentFrame();
  const lines = [
    "In a war, help is often minutes too far away.",
    "The brain dies in 4 minutes. The ambulance comes in 10–20.",
    "SaveVision puts a doctor behind every pair of eyes —",
    "so anyone, anywhere, can save a life.",
  ];
  return (
    <AbsoluteFill style={{ background: "linear-gradient(180deg,#1a1208,#0a0e13 70%)", justifyContent: "center", alignItems: "center" }}>
      <div style={{ position: "absolute", inset: 0, background: "radial-gradient(circle at 50% 120%, #6b4a1f55, transparent 60%)" }} />
      <div style={{ textAlign: "center", padding: "0 8%" }}>
        {lines.map((l, i) => {
          const start = 30 + i * 70;
          const op = interpolate(f, [start, start + 22], [0, 1], { extrapolateLeft: "clamp", extrapolateRight: "clamp" });
          const last = i === lines.length - 1;
          return (
            <div
              key={i}
              style={{
                opacity: op,
                color: last ? ACCENT : "#eafff5",
                fontFamily: "Helvetica, Arial",
                fontWeight: last ? 900 : 600,
                fontSize: last ? 54 : 40,
                margin: "18px 0",
                textShadow: "0 2px 14px #000",
              }}
            >
              {l}
            </div>
          );
        })}
      </div>
    </AbsoluteFill>
  );
};

/* ---------------- Scene 9 — logo ---------------- */
const Logo: React.FC<{ dur: number }> = ({ dur }) => {
  const o = useFade(dur, 18, 18);
  return (
    <AbsoluteFill style={{ background: "#05070a", justifyContent: "center", alignItems: "center" }}>
      <div style={{ opacity: o, textAlign: "center", fontFamily: "Helvetica, Arial" }}>
        <div style={{ fontSize: 86, fontWeight: 900, color: "#eafff5" }}>
          Save<span style={{ color: ACCENT }}>Vision</span>
        </div>
        <div style={{ fontSize: 30, color: "#8b9aa3", marginTop: 14 }}>
          Remote medical guidance on smart glasses
        </div>
        <div style={{ fontSize: 22, color: "#5d6b73", marginTop: 8 }}>for war and emergency zones</div>
      </div>
    </AbsoluteFill>
  );
};

export const SaveVisionFilm: React.FC = () => {
  return (
    <AbsoluteFill style={{ background: "#000" }}>
      <Series>
        <Series.Sequence durationInFrames={150}><ColdOpen dur={150} /></Series.Sequence>
        <Series.Sequence durationInFrames={270}><Rider dur={270} /></Series.Sequence>
        <Series.Sequence durationInFrames={240}><Girl dur={240} /></Series.Sequence>
        <Series.Sequence durationInFrames={270}><Drone dur={270} /></Series.Sequence>
        <Series.Sequence durationInFrames={150}><Strike dur={150} /></Series.Sequence>
        <Series.Sequence durationInFrames={600}><Rescue dur={600} /></Series.Sequence>
        <Series.Sequence durationInFrames={300}><Ambulance dur={300} /></Series.Sequence>
        <Series.Sequence durationInFrames={420}><Close dur={420} /></Series.Sequence>
        <Series.Sequence durationInFrames={150}><Logo dur={150} /></Series.Sequence>
      </Series>
    </AbsoluteFill>
  );
};
