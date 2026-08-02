import React from "react";
import {
  AbsoluteFill,
  interpolate,
  spring,
  useCurrentFrame,
  useVideoConfig,
} from "remotion";
import { COLORS, FONT_MONO, FONT_SANS } from "./theme";

export const SceneFade: React.FC<{
  duration: number;
  children: React.ReactNode;
}> = ({ duration, children }) => {
  const frame = useCurrentFrame();
  const opacity = interpolate(frame, [0, 12, duration - 12, duration], [0, 1, 1, 0], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });
  return (
    <AbsoluteFill style={{ backgroundColor: COLORS.bgDeep, opacity, fontFamily: FONT_SANS }}>
      {children}
    </AbsoluteFill>
  );
};

export const BackgroundGrid: React.FC = () => (
  <AbsoluteFill
    style={{
      backgroundImage:
        "linear-gradient(rgba(255,255,255,0.028) 1px, transparent 1px), linear-gradient(90deg, rgba(255,255,255,0.028) 1px, transparent 1px)",
      backgroundSize: "74px 74px",
      maskImage: "linear-gradient(to bottom, black, transparent 90%)",
    }}
  />
);

export const Glow: React.FC<{
  x: string;
  y: string;
  size?: number;
  color?: string;
  opacity?: number;
}> = ({ x, y, size = 900, color = COLORS.orange, opacity = 0.18 }) => (
  <div
    style={{
      position: "absolute",
      left: x,
      top: y,
      width: size,
      height: size,
      transform: "translate(-50%, -50%)",
      background: `radial-gradient(circle, ${color} 0%, transparent 67%)`,
      opacity,
      pointerEvents: "none",
    }}
  />
);

export const Rise: React.FC<{
  delay: number;
  children: React.ReactNode;
  style?: React.CSSProperties;
}> = ({ delay, children, style }) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const s = spring({ frame: frame - delay, fps, config: { damping: 200 } });
  return (
    <div style={{ opacity: s, transform: `translateY(${(1 - s) * 34}px)`, ...style }}>
      {children}
    </div>
  );
};

export const Badge: React.FC<{
  children: React.ReactNode;
  delay?: number;
  tone?: "orange" | "blue" | "mint";
}> = ({ children, delay = 0, tone = "orange" }) => {
  const color = tone === "blue" ? COLORS.blue : tone === "mint" ? COLORS.mint : COLORS.orange;
  return (
    <Rise delay={delay}>
      <div
        style={{
          display: "inline-flex",
          padding: "10px 26px",
          borderRadius: 999,
          border: `1px solid ${color}77`,
          background: `${color}18`,
          color,
          fontSize: 25,
          fontWeight: 700,
          letterSpacing: 4,
          textTransform: "uppercase",
        }}
      >
        {children}
      </div>
    </Rise>
  );
};

export const StepHeader: React.FC<{
  eyebrow: string;
  title: string;
  delay?: number;
  tone?: "orange" | "blue";
}> = ({ eyebrow, title, delay = 0, tone = "orange" }) => (
  <div>
    <Rise delay={delay}>
      <div
        style={{
          color: tone === "blue" ? COLORS.blue : COLORS.orange,
          fontSize: 24,
          fontWeight: 760,
          letterSpacing: 4,
          textTransform: "uppercase",
          marginBottom: 12,
        }}
      >
        {eyebrow}
      </div>
    </Rise>
    <Rise delay={delay + 6}>
      <div style={{ fontSize: 68, fontWeight: 850, color: COLORS.text, letterSpacing: -2, lineHeight: 1.02 }}>
        {title}
      </div>
    </Rise>
  </div>
);

export const PathCard: React.FC<{
  label: string;
  detail?: string;
  delay: number;
  accent?: string;
}> = ({ label, detail, delay, accent = COLORS.blue }) => (
  <Rise delay={delay} style={{ flex: 1 }}>
    <div
      style={{
        height: 142,
        padding: "26px 30px",
        borderRadius: 24,
        background: "rgba(255,255,255,0.065)",
        border: `1px solid ${COLORS.border}`,
        boxShadow: "0 24px 60px rgba(0,0,0,0.2)",
        display: "flex",
        flexDirection: "column",
        justifyContent: "center",
      }}
    >
      <div style={{ fontSize: 33, fontWeight: 790, color: COLORS.text }}>{label}</div>
      {detail ? <div style={{ fontSize: 22, color: COLORS.muted, marginTop: 9 }}>{detail}</div> : null}
      <div style={{ height: 4, width: 52, borderRadius: 2, background: accent, marginTop: 15 }} />
    </div>
  </Rise>
);

export const FeatureChip: React.FC<{
  children: React.ReactNode;
  delay: number;
  tone?: "orange" | "mint" | "blue";
}> = ({ children, delay, tone = "orange" }) => {
  const color = tone === "mint" ? COLORS.mint : tone === "blue" ? COLORS.blue : COLORS.orange;
  return (
    <Rise delay={delay}>
      <div
        style={{
          padding: "18px 28px",
          borderRadius: 18,
          background: `${color}14`,
          border: `1px solid ${color}66`,
          color: COLORS.text,
          fontSize: 27,
          fontWeight: 690,
          whiteSpace: "nowrap",
        }}
      >
        <span style={{ color, marginRight: 12 }}>●</span>
        {children}
      </div>
    </Rise>
  );
};

export const UrlPill: React.FC<{ url: string; delay?: number; fontSize?: number }> = ({
  url,
  delay = 0,
  fontSize = 40,
}) => {
  const frame = useCurrentFrame();
  const { fps } = useVideoConfig();
  const s = spring({ frame: frame - delay, fps, config: { damping: 15, mass: 0.8 } });
  return (
    <div
      style={{
        display: "inline-block",
        padding: "26px 44px",
        borderRadius: 18,
        background: COLORS.bgCard,
        border: `2px solid ${COLORS.orange}`,
        color: COLORS.text,
        fontFamily: FONT_MONO,
        fontSize,
        boxShadow: `0 0 70px ${COLORS.orange}44`,
        opacity: Math.min(1, s),
        transform: `scale(${0.9 + s * 0.1})`,
      }}
    >
      {url}
    </div>
  );
};
