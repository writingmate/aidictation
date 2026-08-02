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
  EvidenceShot,
  FactChip,
  Glow,
  Rise,
  SceneFade,
  SceneHeading,
  UrlPill,
} from "./components";
import { COLORS, FONT_MONO, SCENES } from "./theme";

export const TitleScene: React.FC = () => (
  <SceneFade duration={SCENES.title}>
    <Img
      src={staticFile("shot-repo-home.png")}
      style={{ width: "100%", height: "100%", objectFit: "cover", opacity: 0.34 }}
    />
    <AbsoluteFill style={{ background: "linear-gradient(90deg, rgba(11,18,32,0.98) 0%, rgba(11,18,32,0.82) 55%, rgba(11,18,32,0.36) 100%)" }} />
    <BackgroundGrid />
    <Glow x="19%" y="20%" size={1100} color={COLORS.blue} />
    <Glow x="80%" y="78%" size={1200} color={COLORS.orange} />
    <AbsoluteFill style={{ padding: "90px 105px", justifyContent: "center" }}>
      <Badge delay={4} tone="mint">What you can verify</Badge>
      <Rise delay={13} style={{ marginTop: 34 }}>
        <div
          style={{
            color: COLORS.text,
            fontSize: 106,
            fontWeight: 920,
            letterSpacing: -4.2,
            lineHeight: 0.96,
            maxWidth: 1350,
          }}
        >
          Open-Source
          <br />
          <span style={{ color: COLORS.orange }}>Speech to Text</span>
        </div>
      </Rise>
      <Rise delay={27} style={{ marginTop: 29 }}>
        <div style={{ color: COLORS.muted, fontSize: 38, lineHeight: 1.3 }}>
          Inspect the code before you install.
        </div>
      </Rise>
    </AbsoluteFill>
  </SceneFade>
);

export const PublicRepoScene: React.FC = () => (
  <SceneFade duration={SCENES.publicRepo}>
    <BackgroundGrid />
    <Glow x="82%" y="22%" color={COLORS.blue} />
    <AbsoluteFill style={{ padding: "60px 92px" }}>
      <SceneHeading eyebrow="Check 1" title="Start with the public repository" delay={4} />
      <div style={{ display: "flex", gap: 17, marginTop: 28 }}>
        <FactChip delay={22} tone="mint">Public source</FactChip>
        <FactChip delay={29} tone="blue">Apple · Windows · Android</FactChip>
        <FactChip delay={36} tone="orange">MIT license</FactChip>
      </div>
      <div style={{ position: "absolute", left: 190, bottom: -155 }}>
        <EvidenceShot src="shot-repo-home.png" delay={16} width={1540} height={865} />
      </div>
    </AbsoluteFill>
  </SceneFade>
);

export const LicenseScene: React.FC = () => {
  const frame = useCurrentFrame();
  const noticesOpacity = interpolate(frame, [105, 140], [0, 1], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  const licenseOpacity = interpolate(frame, [105, 140], [1, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  return (
    <SceneFade duration={SCENES.license}>
      <BackgroundGrid />
      <Glow x="18%" y="78%" color={COLORS.orange} />
      <AbsoluteFill style={{ padding: "60px 92px" }}>
        <SceneHeading eyebrow="Check 2" title="Read the license — and the notices" delay={4} />
        <Rise delay={20} style={{ marginTop: 20 }}>
          <div style={{ color: COLORS.muted, fontSize: 26 }}>
            MIT covers the repository code. Included third-party components keep their own licenses.
          </div>
        </Rise>
        <div style={{ position: "absolute", left: 190, bottom: -90, opacity: licenseOpacity }}>
          <EvidenceShot src="shot-license.png" delay={14} width={1540} height={815} label="Live MIT License page · 2026-08-02" />
        </div>
        <div style={{ position: "absolute", left: 190, bottom: -90, opacity: noticesOpacity }}>
          <EvidenceShot src="shot-third-party.png" delay={0} width={1540} height={815} label="Live third-party notices · 2026-08-02" />
        </div>
      </AbsoluteFill>
    </SceneFade>
  );
};

export const BuildScene: React.FC = () => (
  <SceneFade duration={SCENES.build}>
    <BackgroundGrid />
    <Glow x="50%" y="80%" size={1300} color={COLORS.mint} />
    <AbsoluteFill style={{ padding: "58px 88px" }}>
      <SceneHeading eyebrow="Check 3" title="Inspect each client or build it yourself" delay={4} />
      <div style={{ display: "flex", gap: 24, marginTop: 40 }}>
        <EvidenceShot
          src="shot-build.png"
          delay={18}
          width={850}
          height={640}
          label="Current build instructions"
          zoomTo={1.02}
        />
        <EvidenceShot
          src="shot-layout.png"
          delay={28}
          width={850}
          height={640}
          label="Current repository layout"
          zoomTo={1.02}
        />
      </div>
    </AbsoluteFill>
  </SceneFade>
);

export const OfflineCloudScene: React.FC = () => (
  <SceneFade duration={SCENES.offlineCloud}>
    <BackgroundGrid />
    <Glow x="22%" y="18%" color={COLORS.mint} />
    <Glow x="80%" y="75%" color={COLORS.blue} />
    <AbsoluteFill style={{ padding: "58px 92px" }}>
      <SceneHeading eyebrow="Check 4" title="Open source and offline are different questions" delay={4} />
      <Rise delay={20} style={{ marginTop: 19 }}>
        <div style={{ color: COLORS.muted, fontSize: 27 }}>
          The README separates on-device recognition, cloud transcription, and optional cleanup.
        </div>
      </Rise>
      <div style={{ position: "absolute", left: 190, bottom: -35 }}>
        <EvidenceShot
          src="shot-offline-cloud.png"
          delay={24}
          width={1540}
          height={820}
          label="Current README processing table · 2026-08-02"
          zoomTo={1.025}
        />
      </div>
    </AbsoluteFill>
  </SceneFade>
);

export const PrivacyScene: React.FC = () => (
  <SceneFade duration={SCENES.privacy}>
    <BackgroundGrid />
    <Glow x="18%" y="65%" size={1050} color={COLORS.orange} />
    <AbsoluteFill style={{ padding: "76px 92px", flexDirection: "row", alignItems: "center", gap: 70 }}>
      <div style={{ width: 740 }}>
        <Badge delay={4} tone="orange">Important boundary</Badge>
        <Rise delay={14} style={{ marginTop: 31 }}>
          <div style={{ color: COLORS.text, fontSize: 70, lineHeight: 1.02, fontWeight: 890, letterSpacing: -2.6 }}>
            Offline recognition
            <br />
            <span style={{ color: COLORS.orange }}>≠</span> fully offline workflow
          </div>
        </Rise>
        <Rise delay={31} style={{ marginTop: 39 }}>
          <div style={{ color: COLORS.muted, fontSize: 30, lineHeight: 1.45 }}>
            Cloud cleanup can still send transcript text after speech was recognized on the device.
          </div>
        </Rise>
        <Rise delay={48} style={{ marginTop: 31 }}>
          <div style={{ color: COLORS.mint, fontSize: 27, fontWeight: 760 }}>
            Disable cloud features when nothing should leave the device.
          </div>
        </Rise>
      </div>
      <EvidenceShot
        src="shot-privacy.png"
        delay={20}
        width={990}
        height={710}
        label="Current README privacy section · 2026-08-02"
        zoomTo={1.02}
      />
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
      <AbsoluteFill style={{ alignItems: "center", justifyContent: "center", gap: 27, textAlign: "center" }}>
        <Rise delay={4}>
          <Img
            src={staticFile("aidictation-icon.png")}
            style={{ width: 135, height: 135, borderRadius: 31, boxShadow: "0 28px 80px rgba(0,0,0,0.45)" }}
          />
        </Rise>
        <Rise delay={12}>
          <div style={{ fontSize: 72, fontWeight: 890, color: COLORS.text, letterSpacing: -2.5 }}>
            Inspect the source. Then decide.
          </div>
        </Rise>
        <div style={{ transform: `scale(${pulse})` }}>
          <UrlPill url="github.com/writingmate/aidictation" delay={23} fontSize={38} />
        </div>
        <Rise delay={39}>
          <div style={{ fontFamily: FONT_MONO, fontSize: 27, color: COLORS.mint }}>aidictation.com</div>
        </Rise>
      </AbsoluteFill>
    </SceneFade>
  );
};

export const Thumbnail: React.FC = () => (
  <AbsoluteFill style={{ backgroundColor: COLORS.bgDeep, fontFamily: FONT_MONO }}>
    <Img src={staticFile("shot-repo-home.png")} style={{ width: "100%", height: "100%", objectFit: "cover", opacity: 0.38 }} />
    <AbsoluteFill style={{ background: "linear-gradient(90deg, rgba(11,18,32,0.99) 0%, rgba(11,18,32,0.91) 58%, rgba(11,18,32,0.48) 100%)" }} />
    <BackgroundGrid />
    <Glow x="20%" y="18%" size={1050} color={COLORS.blue} />
    <Glow x="80%" y="76%" size={1200} color={COLORS.orange} />
    <AbsoluteFill style={{ padding: "82px 96px" }}>
      <div style={{ display: "flex", alignItems: "center", gap: 20 }}>
        <Img src={staticFile("aidictation-icon.png")} style={{ width: 94, height: 94, borderRadius: 22 }} />
        <div style={{ color: COLORS.mint, fontSize: 27, fontWeight: 780, letterSpacing: 2.8 }}>
          OPEN-SOURCE SPEECH TO TEXT
        </div>
      </div>
      <div
        style={{
          marginTop: 77,
          color: COLORS.text,
          fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif',
          fontSize: 127,
          lineHeight: 0.92,
          fontWeight: 940,
          letterSpacing: -5,
        }}
      >
        CHECK THE
        <br />
        <span style={{ color: COLORS.orange }}>CODE</span>
      </div>
      <div
        style={{
          marginTop: 48,
          display: "inline-flex",
          padding: "18px 29px",
          borderRadius: 16,
          background: COLORS.orange,
          color: COLORS.bgDeep,
          fontSize: 32,
          fontWeight: 850,
          letterSpacing: 1.2,
        }}
      >
        BEFORE YOU INSTALL
      </div>
      <div style={{ position: "absolute", left: 100, bottom: 66, color: COLORS.mint, fontSize: 25, fontWeight: 720 }}>
        github.com/writingmate/aidictation
      </div>
    </AbsoluteFill>
  </AbsoluteFill>
);
