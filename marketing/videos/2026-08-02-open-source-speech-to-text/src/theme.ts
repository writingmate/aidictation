export const COLORS = {
  bg: "#111827",
  bgDeep: "#0b1220",
  bgCard: "#182238",
  orange: "#ff7a1a",
  orangeSoft: "#ffb47a",
  mint: "#8df0bd",
  blue: "#7db7ff",
  text: "#f7f9ff",
  muted: "#b6c0d4",
  border: "rgba(255,255,255,0.14)",
};

export const FONT_SANS =
  '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif';
export const FONT_MONO =
  '"SF Mono", ui-monospace, Menlo, Monaco, "Cascadia Mono", monospace';

export const FPS = 30;

// Exactly 60 seconds. Re-time after measuring the generated per-scene narration.
export const SCENES = {
  title: 210,
  publicRepo: 225,
  license: 270,
  build: 210,
  offlineCloud: 330,
  privacy: 300,
  cta: 255,
};

export const TOTAL_DURATION = Object.values(SCENES).reduce((sum, frames) => sum + frames, 0);
