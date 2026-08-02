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
  FactCard,
  FeatureChip,
  Glow,
  PhoneShot,
  Rise,
  SceneFade,
  SceneHeading,
  UrlPill,
} from "./components";
import { COLORS, FONT_MONO, SCENES } from "./theme";

const CAPTURE_ROOT = "current-captures";

export const TitleScene: React.FC = () => (
  <SceneFade duration={SCENES.title}>
    <BackgroundGrid />
    <Glow x="18%" y="15%" size={1050} color={COLORS.blue} />
    <Glow x="78%" y="76%" size={1150} color={COLORS.orange} />
    <AbsoluteFill style={{ padding: "86px 105px", flexDirection: "row", alignItems: "center" }}>
      <div style={{ width: 1110 }}>
        <Badge delay={4} tone="mint">Voice typing Android</Badge>
        <Rise delay={13} style={{ marginTop: 35 }}>
          <div
            style={{
              color: COLORS.text,
              fontSize: 111,
              fontWeight: 910,
              letterSpacing: -4.4,
              lineHeight: 0.94,
            }}
          >
            Keep Your
            <br />
            <span style={{ color: COLORS.orange }}>Keyboard</span>
          </div>
        </Rise>
        <Rise delay={26} style={{ marginTop: 31 }}>
          <div style={{ color: COLORS.muted, fontSize: 38, lineHeight: 1.28, maxWidth: 950 }}>
            Add a floating mic beside supported text fields.
          </div>
        </Rise>
      </div>
      <div style={{ position: "absolute", right: 110, top: 70 }}>
        <PhoneShot src={`${CAPTURE_ROOT}/shot-floating-mic.png`} delay={12} width={455} />
      </div>
    </AbsoluteFill>
  </SceneFade>
);

export const PermissionsScene: React.FC = () => (
  <SceneFade duration={SCENES.permissions}>
    <BackgroundGrid />
    <Glow x="12%" y="55%" color={COLORS.blue} />
    <AbsoluteFill style={{ padding: "72px 105px", flexDirection: "row", alignItems: "center", gap: 115 }}>
      <PhoneShot
        src={`${CAPTURE_ROOT}/shot-accessibility-disclosure.png`}
        delay={8}
        width={430}
        label="Current setup screen"
      />
      <div style={{ flex: 1 }}>
        <SceneHeading eyebrow="Setup" title="Two permissions, explained before you enable them" delay={4} />
        <div style={{ display: "flex", gap: 24, marginTop: 52 }}>
          <FactCard
            title="Microphone"
            detail="Records only when you start dictating."
            delay={22}
            tone="orange"
          />
          <FactCard
            title="Accessibility"
            detail="Finds the active field and inserts the finished text."
            delay={31}
            tone="blue"
          />
        </div>
        <Rise delay={48} style={{ marginTop: 29 }}>
          <div style={{ color: COLORS.muted, fontSize: 23 }}>
            Password and other secure fields are excluded.
          </div>
        </Rise>
      </div>
    </AbsoluteFill>
  </SceneFade>
);

export const FocusScene: React.FC = () => (
  <SceneFade duration={SCENES.focus}>
    <BackgroundGrid />
    <Glow x="84%" y="20%" color={COLORS.orange} />
    <AbsoluteFill style={{ padding: "76px 105px", flexDirection: "row", alignItems: "center" }}>
      <div style={{ width: 1050 }}>
        <SceneHeading eyebrow="Step 1" title="Tap a supported text field" delay={4} />
        <Rise delay={22} style={{ marginTop: 44 }}>
          <div style={{ color: COLORS.muted, fontSize: 35, lineHeight: 1.38, maxWidth: 860 }}>
            Your regular Android keyboard stays open. The floating microphone appears beside the field.
          </div>
        </Rise>
        <div style={{ display: "flex", gap: 18, marginTop: 42 }}>
          <FeatureChip delay={34} tone="mint">Keep your keyboard</FeatureChip>
          <FeatureChip delay={42} tone="orange">Mic appears by the field</FeatureChip>
        </div>
      </div>
      <div style={{ position: "absolute", right: 135, top: 77 }}>
        <PhoneShot src={`${CAPTURE_ROOT}/shot-field-focused.png`} delay={12} width={435} />
      </div>
    </AbsoluteFill>
  </SceneFade>
);

export const DictateScene: React.FC = () => {
  const frame = useCurrentFrame();
  const resultOpacity = interpolate(frame, [120, 155], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const pulse = 1 + Math.sin(frame / 7) * 0.025;

  return (
    <SceneFade duration={SCENES.dictate}>
      <BackgroundGrid />
      <Glow x="22%" y="72%" size={1000} color={COLORS.orange} />
      <AbsoluteFill style={{ padding: "72px 105px", flexDirection: "row", alignItems: "center", gap: 115 }}>
        <div style={{ position: "relative", width: 430, height: 895 }}>
          <div style={{ position: "absolute", inset: 0 }}>
            <PhoneShot src={`${CAPTURE_ROOT}/shot-field-focused.png`} delay={7} width={430} />
          </div>
          <div style={{ position: "absolute", inset: 0, opacity: resultOpacity }}>
            <PhoneShot src={`${CAPTURE_ROOT}/shot-result.png`} delay={0} width={430} label="Real synthetic result" />
          </div>
        </div>
        <div style={{ flex: 1 }}>
          <SceneHeading eyebrow="Step 2" title="Tap · Speak · Tap" delay={4} />
          <Rise delay={23} style={{ marginTop: 50 }}>
            <div
              style={{
                width: 178,
                height: 178,
                borderRadius: 89,
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
                background: COLORS.orange,
                boxShadow: `0 0 85px ${COLORS.orange}77`,
                transform: `scale(${pulse})`,
                color: COLORS.bgDeep,
                fontSize: 74,
                fontWeight: 900,
              }}
            >
              ●
            </div>
          </Rise>
          <Rise delay={42} style={{ marginTop: 40 }}>
            <div style={{ color: COLORS.muted, fontSize: 34, lineHeight: 1.4, maxWidth: 840 }}>
              When processing finishes, the text is inserted at the cursor.
            </div>
          </Rise>
        </div>
      </AbsoluteFill>
    </SceneFade>
  );
};

export const ModesScene: React.FC = () => (
  <SceneFade duration={SCENES.modes}>
    <BackgroundGrid />
    <Glow x="22%" y="30%" color={COLORS.mint} />
    <Glow x="78%" y="70%" color={COLORS.blue} />
    <AbsoluteFill style={{ padding: "78px 105px" }}>
      <SceneHeading eyebrow="Choose in Settings" title="Offline recognition or cloud transcription" delay={4} />
      <div style={{ display: "flex", gap: 32, marginTop: 66 }}>
        <FactCard
          title="Offline recognition"
          detail="Speech is recognized on the device. A model download may be needed first."
          delay={24}
          tone="mint"
        />
        <FactCard
          title="Cloud transcription"
          detail="Relevant audio is sent for remote speech processing when you choose cloud mode."
          delay={34}
          tone="blue"
        />
      </div>
      <Rise delay={53} style={{ marginTop: 34 }}>
        <div style={{ color: COLORS.muted, fontSize: 24 }}>
          Offline recognition and optional cloud cleanup are separate choices.
        </div>
      </Rise>
    </AbsoluteFill>
  </SceneFade>
);

export const CustomizeScene: React.FC = () => (
  <SceneFade duration={SCENES.customize}>
    <BackgroundGrid />
    <Glow x="50%" y="62%" size={1350} color={COLORS.orange} />
    <AbsoluteFill style={{ padding: "82px 105px", alignItems: "center", textAlign: "center" }}>
      <Badge delay={4} tone="orange">Optional cloud features</Badge>
      <Rise delay={13} style={{ marginTop: 30 }}>
        <div style={{ color: COLORS.text, fontSize: 78, fontWeight: 880, letterSpacing: -2.8 }}>
          Shape the finished text
        </div>
      </Rise>
      <Rise delay={23} style={{ marginTop: 20 }}>
        <div style={{ color: COLORS.muted, fontSize: 31, maxWidth: 1200, lineHeight: 1.35 }}>
          Cloud processing can use the context you choose to provide.
        </div>
      </Rise>
      <div style={{ display: "flex", flexWrap: "wrap", justifyContent: "center", gap: 22, marginTop: 57 }}>
        <FeatureChip delay={36} tone="orange">Cleanup</FeatureChip>
        <FeatureChip delay={43} tone="mint">Personal vocabulary</FeatureChip>
        <FeatureChip delay={50} tone="blue">Writing rules</FeatureChip>
        <FeatureChip delay={57} tone="orange">Spoken shortcuts</FeatureChip>
      </div>
      <Rise delay={72} style={{ marginTop: 45 }}>
        <div style={{ color: COLORS.muted, fontSize: 23 }}>
          Relevant transcript text may be processed remotely when cloud features are enabled.
        </div>
      </Rise>
    </AbsoluteFill>
  </SceneFade>
);

export const CtaScene: React.FC = () => {
  const frame = useCurrentFrame();
  const pulse = 1 + Math.sin(frame / 10) * 0.012;

  return (
    <SceneFade duration={SCENES.cta}>
      <BackgroundGrid />
      <Glow x="50%" y="52%" size={1450} color={COLORS.orange} />
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 31, textAlign: "center" }}>
        <Rise delay={4}>
          <Img
            src={staticFile("aidictation-icon.png")}
            style={{
              width: 143,
              height: 143,
              borderRadius: 33,
              boxShadow: "0 28px 80px rgba(0,0,0,0.45)",
            }}
          />
        </Rise>
        <Rise delay={13}>
          <div style={{ fontSize: 78, fontWeight: 880, color: COLORS.text, letterSpacing: -2.5 }}>
            AI Dictation is open source
          </div>
        </Rise>
        <div style={{ transform: `scale(${pulse})` }}>
          <UrlPill url="aidictation.com" delay={24} fontSize={44} />
        </div>
        <Rise delay={39}>
          <div style={{ fontFamily: FONT_MONO, fontSize: 25, color: COLORS.mint }}>
            github.com/writingmate/aidictation
          </div>
        </Rise>
      </AbsoluteFill>
    </SceneFade>
  );
};

export const Thumbnail: React.FC = () => (
  <AbsoluteFill style={{ backgroundColor: COLORS.bgDeep, fontFamily: FONT_MONO }}>
    <BackgroundGrid />
    <Glow x="18%" y="12%" size={1100} color={COLORS.blue} />
    <Glow x="80%" y="72%" size={1250} color={COLORS.orange} />
    <AbsoluteFill style={{ padding: "82px 98px", flexDirection: "row", alignItems: "center" }}>
      <div style={{ width: 1180 }}>
        <div style={{ display: "flex", alignItems: "center", gap: 20 }}>
          <Img src={staticFile("aidictation-icon.png")} style={{ width: 96, height: 96, borderRadius: 23 }} />
          <div style={{ color: COLORS.muted, fontSize: 27, fontWeight: 760, letterSpacing: 2.5 }}>
            VOICE TYPING ANDROID
          </div>
        </div>
        <div
          style={{
            marginTop: 56,
            color: COLORS.text,
            fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
            fontSize: 114,
            lineHeight: 0.94,
            fontWeight: 930,
            letterSpacing: -4.4,
          }}
        >
          KEEP YOUR
          <br />
          <span style={{ color: COLORS.orange }}>KEYBOARD</span>
        </div>
        <div style={{ marginTop: 42, color: COLORS.mint, fontSize: 37, fontWeight: 800 }}>
          ADD A FLOATING MIC
        </div>
      </div>
      <div style={{ position: "absolute", right: 115, top: 64 }}>
        <PhoneShot src={`${CAPTURE_ROOT}/shot-floating-mic.png`} width={460} label="Current Android capture" />
      </div>
    </AbsoluteFill>
  </AbsoluteFill>
);
