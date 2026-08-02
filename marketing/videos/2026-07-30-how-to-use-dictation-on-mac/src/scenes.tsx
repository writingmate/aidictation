import React from "react";
import {
  AbsoluteFill,
  Img,
  interpolate,
  staticFile,
  useCurrentFrame,
} from "remotion";
import {
  BackgroundGrid,
  Badge,
  FeatureChip,
  Glow,
  PathCard,
  Rise,
  SceneFade,
  StepHeader,
  UrlPill,
} from "./components";
import { COLORS, FONT_MONO, SCENES } from "./theme";

const DOWNLOAD_URL = "aidictation.com/download";

export const TitleScene: React.FC = () => (
  <SceneFade duration={SCENES.title}>
    <BackgroundGrid />
    <Glow x="22%" y="20%" size={1150} color={COLORS.blue} />
    <Glow x="78%" y="72%" size={1150} color={COLORS.orange} />
    <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", textAlign: "center", gap: 34 }}>
      <Badge delay={3} tone="mint">Mac voice typing guide</Badge>
      <Rise delay={12}>
        <div style={{ fontSize: 112, fontWeight: 890, color: COLORS.text, letterSpacing: -4, lineHeight: 1 }}>
          How to Use
          <br />
          Dictation on Mac
        </div>
      </Rise>
      <Rise delay={24}>
        <div style={{ display: "flex", alignItems: "center", gap: 18, fontSize: 40, color: COLORS.muted }}>
          <span style={{ color: COLORS.blue, fontWeight: 780 }}>Built-In</span>
          <span>+</span>
          <span style={{ color: COLORS.orange, fontWeight: 780 }}>AI Dictation</span>
        </div>
      </Rise>
    </AbsoluteFill>
  </SceneFade>
);

export const BuiltInSetupScene: React.FC = () => (
  <SceneFade duration={SCENES.builtInSetup}>
    <BackgroundGrid />
    <Glow x="12%" y="40%" color={COLORS.blue} />
    <AbsoluteFill style={{ padding: "84px 110px" }}>
      <StepHeader eyebrow="Built-in Dictation · Setup" title="Turn it on in Keyboard settings" delay={4} tone="blue" />
      <div style={{ display: "flex", alignItems: "center", gap: 20, marginTop: 92 }}>
        <PathCard label="System Settings" detail="Open from the Apple menu" delay={22} accent={COLORS.blue} />
        <Rise delay={30}><div style={{ color: COLORS.blue, fontSize: 42 }}>›</div></Rise>
        <PathCard label="Keyboard" detail="Scroll to Dictation" delay={36} accent={COLORS.blue} />
        <Rise delay={44}><div style={{ color: COLORS.blue, fontSize: 42 }}>›</div></Rise>
        <PathCard label="Dictation: On" detail="Confirm Enable" delay={50} accent={COLORS.blue} />
      </div>
      <div style={{ display: "flex", justifyContent: "center", gap: 22, marginTop: 46 }}>
        <FeatureChip delay={66} tone="blue">Language</FeatureChip>
        <FeatureChip delay={72} tone="blue">Microphone</FeatureChip>
        <FeatureChip delay={78} tone="blue">Shortcut</FeatureChip>
      </div>
      <Rise delay={90} style={{ position: "absolute", right: 110, bottom: 62 }}>
        <div style={{ color: COLORS.muted, fontSize: 21 }}>Source: Apple Support · current macOS guide</div>
      </Rise>
    </AbsoluteFill>
  </SceneFade>
);

const ActionTile: React.FC<{ n: string; title: string; detail: string; delay: number }> = ({
  n,
  title,
  detail,
  delay,
}) => (
  <Rise delay={delay} style={{ flex: 1 }}>
    <div
      style={{
        minHeight: 230,
        padding: 34,
        borderRadius: 28,
        background: "rgba(125,183,255,0.075)",
        border: `1px solid ${COLORS.blue}55`,
      }}
    >
      <div
        style={{
          width: 54,
          height: 54,
          borderRadius: 17,
          background: COLORS.blue,
          color: COLORS.bgDeep,
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          fontSize: 29,
          fontWeight: 850,
          marginBottom: 24,
        }}
      >
        {n}
      </div>
      <div style={{ color: COLORS.text, fontSize: 34, fontWeight: 790, lineHeight: 1.05 }}>{title}</div>
      <div style={{ color: COLORS.muted, fontSize: 23, lineHeight: 1.3, marginTop: 15 }}>{detail}</div>
    </div>
  </Rise>
);

export const BuiltInUseScene: React.FC = () => (
  <SceneFade duration={SCENES.builtInUse}>
    <BackgroundGrid />
    <Glow x="82%" y="20%" color={COLORS.blue} />
    <AbsoluteFill style={{ padding: "84px 110px" }}>
      <StepHeader eyebrow="Built-in Dictation · Use" title="Put the cursor where you want text" delay={4} tone="blue" />
      <div style={{ display: "flex", gap: 26, marginTop: 72 }}>
        <ActionTile n="1" title="Click a text field" detail="Messages, notes, documents, and other places you can type." delay={22} />
        <ActionTile n="2" title="Start Dictation" detail="Microphone key, your shortcut, or Edit → Start Dictation." delay={32} />
        <ActionTile n="3" title="Speak, then stop" detail="Press Escape, the Microphone key, or the same shortcut." delay={42} />
      </div>
    </AbsoluteFill>
  </SceneFade>
);

const KeyCap: React.FC<{ label: string; delay: number }> = ({ label, delay }) => (
  <Rise delay={delay}>
    <div
      style={{
        width: 250,
        height: 190,
        borderRadius: 34,
        display: "flex",
        alignItems: "center",
        justifyContent: "center",
        background: "linear-gradient(155deg, #f7f9ff, #cbd4e4)",
        color: "#1a2539",
        fontSize: 75,
        fontWeight: 780,
        boxShadow: "0 22px 0 #8e9bb2, 0 42px 80px rgba(0,0,0,0.45)",
        border: "2px solid #ffffff",
      }}
    >
      {label}
    </div>
  </Rise>
);

export const AiShortcutScene: React.FC = () => (
  <SceneFade duration={SCENES.aiShortcut}>
    <BackgroundGrid />
    <Glow x="88%" y="35%" />
    <AbsoluteFill style={{ padding: "76px 96px" }}>
      <div style={{ width: 860 }}>
        <StepHeader eyebrow="AI Dictation · Mac" title="Use your global shortcut" delay={4} />
        <Rise delay={24} style={{ marginTop: 35 }}>
          <div style={{ color: COLORS.muted, fontSize: 31, lineHeight: 1.4, maxWidth: 760 }}>
            Onboarding suggests Fn. You can choose another shortcut in Settings.
          </div>
        </Rise>
        <div style={{ marginTop: 44, display: "flex", flexDirection: "column", gap: 17, maxWidth: 710 }}>
          <Rise delay={38}>
            <div style={{ padding: "21px 28px", borderRadius: 20, background: `${COLORS.orange}18`, border: `1px solid ${COLORS.orange}77`, color: COLORS.text, fontSize: 30, fontWeight: 730 }}>
              <span style={{ color: COLORS.orange }}>Hold</span> for push-to-talk
            </div>
          </Rise>
          <Rise delay={48}>
            <div style={{ padding: "21px 28px", borderRadius: 20, background: `${COLORS.mint}13`, border: `1px solid ${COLORS.mint}66`, color: COLORS.text, fontSize: 30, fontWeight: 730 }}>
              <span style={{ color: COLORS.mint }}>Double-tap</span> for a longer recording
            </div>
          </Rise>
        </div>
      </div>
      <div style={{ position: "absolute", right: 250, top: 310 }}>
        <KeyCap label="fn" delay={18} />
      </div>
      <Rise delay={58} style={{ position: "absolute", right: 188, top: 565 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 16 }}>
          <Img src={staticFile("aidictation-icon.png")} style={{ width: 76, height: 76, borderRadius: 18 }} />
          <div style={{ color: COLORS.text, fontSize: 28, fontWeight: 760 }}>AI Dictation</div>
        </div>
      </Rise>
    </AbsoluteFill>
  </SceneFade>
);

export const AiControlScene: React.FC = () => (
  <SceneFade duration={SCENES.aiControl}>
    <BackgroundGrid />
    <Glow x="16%" y="70%" />
    <AbsoluteFill style={{ padding: "78px 100px" }}>
      <StepHeader eyebrow="AI Dictation · Options" title="Choose how the final text is shaped" delay={4} />
      <div style={{ display: "flex", marginTop: 56, gap: 58, alignItems: "center" }}>
        <Rise delay={20}>
          <div
            style={{
              width: 620,
              height: 520,
              borderRadius: 32,
              overflow: "hidden",
              background: "#ffffff",
              border: `1px solid ${COLORS.border}`,
              boxShadow: "0 36px 90px rgba(0,0,0,0.35)",
              display: "flex",
              alignItems: "center",
              justifyContent: "center",
            }}
          >
            <Img src={staticFile("aidictation-dictation.png")} style={{ width: 570, height: "auto" }} />
          </div>
        </Rise>
        <div style={{ flex: 1 }}>
          <div style={{ display: "flex", flexWrap: "wrap", gap: 17 }}>
            <FeatureChip delay={30} tone="orange">Local recognition*</FeatureChip>
            <FeatureChip delay={37} tone="mint">Cloud transcription</FeatureChip>
            <FeatureChip delay={44} tone="blue">Optional cleanup</FeatureChip>
            <FeatureChip delay={51} tone="orange">Personal vocabulary</FeatureChip>
            <FeatureChip delay={58} tone="mint">Replacements</FeatureChip>
            <FeatureChip delay={65} tone="blue">Writing rules</FeatureChip>
            <FeatureChip delay={72} tone="orange">Spoken shortcuts</FeatureChip>
          </div>
          <Rise delay={86} style={{ marginTop: 34 }}>
            <div style={{ fontSize: 22, color: COLORS.muted, lineHeight: 1.35 }}>
              *On supported Macs and languages. Cloud cleanup can still send transcript text when enabled.
            </div>
          </Rise>
        </div>
      </div>
    </AbsoluteFill>
  </SceneFade>
);

const WORDS = "Your finished text appears where you were already writing.".split(" ");

export const AiResultScene: React.FC = () => {
  const frame = useCurrentFrame();
  const shown = Math.floor(
    interpolate(frame, [32, 155], [0, WORDS.length], {
      extrapolateLeft: "clamp",
      extrapolateRight: "clamp",
    }),
  );
  return (
    <SceneFade duration={SCENES.aiResult}>
      <BackgroundGrid />
      <Glow x="50%" y="62%" size={1300} color={COLORS.mint} />
      <AbsoluteFill style={{ padding: "76px 104px" }}>
        <StepHeader eyebrow="AI Dictation · Result" title="Text returns to the active app" delay={4} />
        <Rise delay={22} style={{ marginTop: 60, display: "flex", justifyContent: "center" }}>
          <div
            style={{
              width: 1430,
              borderRadius: 30,
              background: "#f7f9ff",
              border: "1px solid rgba(255,255,255,0.7)",
              boxShadow: "0 44px 120px rgba(0,0,0,0.46)",
              padding: "42px 52px 50px",
            }}
          >
            <div style={{ display: "flex", gap: 12, marginBottom: 38 }}>
              <div style={{ width: 14, height: 14, borderRadius: 7, background: "#ff5f57" }} />
              <div style={{ width: 14, height: 14, borderRadius: 7, background: "#febc2e" }} />
              <div style={{ width: 14, height: 14, borderRadius: 7, background: "#28c840" }} />
              <div style={{ marginLeft: 14, fontSize: 19, color: "#8b95a7" }}>Conceptual text field</div>
            </div>
            <div style={{ color: "#27334a", fontSize: 50, lineHeight: 1.35, fontWeight: 520 }}>
              {WORDS.slice(0, shown).join(" ")}
              <span style={{ color: COLORS.orange }}>{shown < WORDS.length ? " ▍" : ""}</span>
            </div>
            <div style={{ marginTop: 44, fontSize: 22, color: "#7a8495" }}>
              AI Dictation inserts finished text into supported active apps.
            </div>
          </div>
        </Rise>
      </AbsoluteFill>
    </SceneFade>
  );
};

export const CtaScene: React.FC = () => {
  const frame = useCurrentFrame();
  const pulse = 1 + Math.sin(frame / 10) * 0.012;
  return (
    <SceneFade duration={SCENES.cta}>
      <BackgroundGrid />
      <Glow x="50%" y="55%" size={1450} />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 34, textAlign: "center" }}>
        <Rise delay={4}>
          <Img src={staticFile("aidictation-icon.png")} style={{ width: 150, height: 150, borderRadius: 34, boxShadow: "0 28px 80px rgba(0,0,0,0.45)" }} />
        </Rise>
        <Rise delay={12}>
          <div style={{ fontSize: 78, fontWeight: 860, color: COLORS.text, letterSpacing: -2.5 }}>Need more control?</div>
        </Rise>
        <Rise delay={20}>
          <div style={{ fontSize: 32, color: COLORS.muted }}>Try the open-source AI Dictation app.</div>
        </Rise>
        <div style={{ transform: `scale(${pulse})` }}>
          <UrlPill url={DOWNLOAD_URL} delay={30} fontSize={42} />
        </div>
        <Rise delay={42}>
          <div style={{ fontFamily: FONT_MONO, fontSize: 24, color: COLORS.mint }}>github.com/writingmate/aidictation</div>
        </Rise>
      </AbsoluteFill>
    </SceneFade>
  );
};

export const Thumbnail: React.FC = () => (
  <AbsoluteFill style={{ backgroundColor: COLORS.bgDeep, fontFamily: "-apple-system, BlinkMacSystemFont, Segoe UI, sans-serif" }}>
    <BackgroundGrid />
    <Glow x="20%" y="20%" size={1000} color={COLORS.blue} />
    <Glow x="82%" y="75%" size={1100} color={COLORS.orange} />
    <AbsoluteFill style={{ padding: "92px 100px" }}>
      <div style={{ display: "flex", alignItems: "center", gap: 22 }}>
        <Img src={staticFile("aidictation-icon.png")} style={{ width: 105, height: 105, borderRadius: 24 }} />
        <div style={{ color: COLORS.muted, fontSize: 27, fontWeight: 700, letterSpacing: 3, textTransform: "uppercase" }}>AI Dictation</div>
      </div>
      <div style={{ marginTop: 62, fontSize: 108, fontWeight: 900, lineHeight: 0.94, letterSpacing: -4, color: COLORS.text }}>
        DICTATION
        <br />
        ON MAC
      </div>
      <div style={{ display: "flex", alignItems: "center", gap: 18, marginTop: 34, fontSize: 39 }}>
        <span style={{ color: COLORS.blue, fontWeight: 800 }}>BUILT-IN</span>
        <span style={{ color: COLORS.muted }}>+</span>
        <span style={{ color: COLORS.orange, fontWeight: 800 }}>AI</span>
      </div>
      <div
        style={{
          position: "absolute",
          right: 80,
          bottom: -46,
          width: 820,
          height: 820,
          borderRadius: 54,
          background: "rgba(255,255,255,0.98)",
          border: `1px solid ${COLORS.border}`,
          boxShadow: "0 48px 130px rgba(0,0,0,0.5)",
          display: "flex",
          alignItems: "center",
          justifyContent: "center",
          transform: "rotate(-3deg)",
        }}
      >
        <Img src={staticFile("aidictation-dictation.png")} style={{ width: 740, height: "auto" }} />
      </div>
    </AbsoluteFill>
  </AbsoluteFill>
);
