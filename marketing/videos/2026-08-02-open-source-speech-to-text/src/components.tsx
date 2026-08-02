import React from "react";
import {
  AbsoluteFill,
  Img,
  interpolate,
  spring,
  staticFile,
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
      maskImage: "linear-gradient(to bottom, black, transparent 94%)",
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
  const entrance = spring({ frame: frame - delay, fps, config: { damping: 200 } });

  return (
    <div
      style={{
        opacity: entrance,
        transform: `translateY(${(1 - entrance) * 34}px)`,
        ...style,
      }}
    >
      {children}
    </div>
  );
};

export const Badge: React.FC<{
  children: React.ReactNode;
  delay?: number;
  tone?: "orange" | "mint" | "blue";
}> = ({ children, delay = 0, tone = "orange" }) => {
  const color = tone === "mint" ? COLORS.mint : tone === "blue" ? COLORS.blue : COLORS.orange;
  return (
    <Rise delay={delay}>
      <div
        style={{
          display: "inline-flex",
          padding: "10px 25px",
          borderRadius: 999,
          border: `1px solid ${color}77`,
          background: `${color}18`,
          color,
          fontSize: 23,
          fontWeight: 770,
          letterSpacing: 3.2,
          textTransform: "uppercase",
        }}
      >
        {children}
      </div>
    </Rise>
  );
};

export const EvidenceShot: React.FC<{
  src: string;
  delay?: number;
  width?: number;
  height?: number;
  label?: string;
  zoomTo?: number;
}> = ({
  src,
  delay = 0,
  width = 1540,
  height = 815,
  label = "Captured from the public repository · 2026-08-02",
  zoomTo = 1.035,
}) => {
  const frame = useCurrentFrame();
  const { fps, durationInFrames } = useVideoConfig();
  const entrance = spring({ frame: frame - delay, fps, config: { damping: 200 } });
  const zoom = interpolate(frame, [0, durationInFrames], [1, zoomTo], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  return (
    <div
      style={{
        width,
        height,
        borderRadius: 25,
        overflow: "hidden",
        position: "relative",
        background: "#ffffff",
        border: `1px solid ${COLORS.border}`,
        boxShadow: `0 44px 115px rgba(0,0,0,0.5), 0 0 75px ${COLORS.orange}18`,
        opacity: entrance,
        transform: `translateY(${(1 - entrance) * 48}px)`,
      }}
    >
      <Img
        src={staticFile(src)}
        style={{
          width: "100%",
          height: "100%",
          objectFit: "cover",
          transform: `scale(${zoom})`,
        }}
      />
      <div
        style={{
          position: "absolute",
          left: 18,
          bottom: 17,
          borderRadius: 999,
          padding: "8px 14px",
          background: "rgba(11,18,32,0.82)",
          border: "1px solid rgba(255,255,255,0.2)",
          color: COLORS.text,
          fontSize: 15,
          fontWeight: 710,
          letterSpacing: 0.4,
        }}
      >
        {label}
      </div>
    </div>
  );
};

export const SceneHeading: React.FC<{
  eyebrow: string;
  title: string;
  delay?: number;
}> = ({ eyebrow, title, delay = 0 }) => (
  <div>
    <Rise delay={delay}>
      <div
        style={{
          color: COLORS.orange,
          fontSize: 22,
          fontWeight: 790,
          letterSpacing: 3.7,
          textTransform: "uppercase",
          marginBottom: 12,
        }}
      >
        {eyebrow}
      </div>
    </Rise>
    <Rise delay={delay + 6}>
      <div
        style={{
          color: COLORS.text,
          fontSize: 67,
          fontWeight: 880,
          letterSpacing: -2.3,
          lineHeight: 1.02,
        }}
      >
        {title}
      </div>
    </Rise>
  </div>
);

export const FactChip: React.FC<{
  children: React.ReactNode;
  delay: number;
  tone?: "orange" | "mint" | "blue";
}> = ({ children, delay, tone = "orange" }) => {
  const color = tone === "mint" ? COLORS.mint : tone === "blue" ? COLORS.blue : COLORS.orange;
  return (
    <Rise delay={delay}>
      <div
        style={{
          padding: "17px 25px",
          borderRadius: 18,
          background: `${color}15`,
          border: `1px solid ${color}66`,
          color: COLORS.text,
          fontSize: 26,
          fontWeight: 730,
          whiteSpace: "nowrap",
        }}
      >
        <span style={{ color, marginRight: 11 }}>●</span>
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
  const entrance = spring({ frame: frame - delay, fps, config: { damping: 15, mass: 0.8 } });

  return (
    <div
      style={{
        display: "inline-block",
        padding: "23px 40px",
        borderRadius: 18,
        background: COLORS.bgCard,
        border: `2px solid ${COLORS.orange}`,
        color: COLORS.text,
        fontFamily: FONT_MONO,
        fontSize,
        boxShadow: `0 0 70px ${COLORS.orange}44`,
        opacity: Math.min(1, entrance),
        transform: `scale(${0.9 + entrance * 0.1})`,
      }}
    >
      {url}
    </div>
  );
};
