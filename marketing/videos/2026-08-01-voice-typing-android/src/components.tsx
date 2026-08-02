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
          fontSize: 24,
          fontWeight: 760,
          letterSpacing: 3.4,
          textTransform: "uppercase",
        }}
      >
        {children}
      </div>
    </Rise>
  );
};

export const PhoneShot: React.FC<{
  src: string;
  delay?: number;
  width?: number;
  label?: string;
}> = ({ src, delay = 0, width = 430, label = "Current Android capture" }) => {
  const frame = useCurrentFrame();
  const { fps, durationInFrames } = useVideoConfig();
  const entrance = spring({ frame: frame - delay, fps, config: { damping: 200 } });
  const zoom = interpolate(frame, [0, durationInFrames], [1, 1.035], {
    extrapolateLeft: "clamp",
    extrapolateRight: "clamp",
  });

  return (
    <div
      style={{
        width,
        height: Math.round(width * 2.08),
        borderRadius: 48,
        padding: 12,
        background: "linear-gradient(160deg, #4c5871, #111827 42%, #020617)",
        border: "1px solid rgba(255,255,255,0.22)",
        boxShadow: `0 46px 110px rgba(0,0,0,0.56), 0 0 75px ${COLORS.orange}22`,
        opacity: entrance,
        transform: `translateY(${(1 - entrance) * 55}px)`,
        overflow: "hidden",
      }}
    >
      <div
        style={{
          width: "100%",
          height: "100%",
          borderRadius: 37,
          overflow: "hidden",
          background: "#000",
          position: "relative",
        }}
      >
        <Img
          src={staticFile(src)}
          style={{
            width: "100%",
            height: "100%",
            objectFit: "cover",
            objectPosition: "center",
            transform: `scale(${zoom})`,
          }}
        />
        <div
          style={{
            position: "absolute",
            left: 18,
            bottom: 18,
            borderRadius: 999,
            padding: "7px 13px",
            color: "#f7f9ff",
            background: "rgba(11,18,32,0.76)",
            border: "1px solid rgba(255,255,255,0.18)",
            fontSize: 14,
            fontWeight: 700,
            letterSpacing: 0.5,
          }}
        >
          {label}
        </div>
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
          fontSize: 23,
          fontWeight: 780,
          letterSpacing: 3.6,
          textTransform: "uppercase",
          marginBottom: 14,
        }}
      >
        {eyebrow}
      </div>
    </Rise>
    <Rise delay={delay + 6}>
      <div
        style={{
          color: COLORS.text,
          fontSize: 69,
          fontWeight: 870,
          letterSpacing: -2.4,
          lineHeight: 1.02,
        }}
      >
        {title}
      </div>
    </Rise>
  </div>
);

export const FactCard: React.FC<{
  title: string;
  detail: string;
  delay: number;
  tone?: "orange" | "mint" | "blue";
}> = ({ title, detail, delay, tone = "orange" }) => {
  const color = tone === "mint" ? COLORS.mint : tone === "blue" ? COLORS.blue : COLORS.orange;
  return (
    <Rise delay={delay} style={{ flex: 1 }}>
      <div
        style={{
          minHeight: 176,
          padding: "28px 31px",
          borderRadius: 25,
          background: COLORS.bgCard,
          border: `1px solid ${color}55`,
          boxShadow: "0 26px 65px rgba(0,0,0,0.24)",
        }}
      >
        <div style={{ color, fontSize: 31, fontWeight: 820 }}>{title}</div>
        <div style={{ color: COLORS.muted, fontSize: 23, lineHeight: 1.35, marginTop: 13 }}>
          {detail}
        </div>
      </div>
    </Rise>
  );
};

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
          padding: "20px 29px",
          borderRadius: 19,
          background: `${color}14`,
          border: `1px solid ${color}66`,
          color: COLORS.text,
          fontSize: 29,
          fontWeight: 720,
          whiteSpace: "nowrap",
        }}
      >
        <span style={{ color, marginRight: 13 }}>●</span>
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
        padding: "25px 43px",
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
