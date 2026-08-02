export const COLORS = {
  bg: "#111827",
  bgDeep: "#0b1220",
  bgCard: "#182238",
  bgCardLight: "#22304a",
  orange: "#ff7a1a",
  orangeSoft: "#ffb47a",
  mint: "#8df0bd",
  blue: "#7db7ff",
  text: "#f7f9ff",
  muted: "#b6c0d4",
  border: "rgba(255,255,255,0.13)",
};

export const FONT_SANS =
  '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif';
export const FONT_MONO =
  '"SF Mono", ui-monospace, Menlo, Monaco, "Cascadia Mono", monospace';

export const FPS = 30;

// Initial target: 58 seconds. Re-timed after the generated narration is measured.
export const SCENES = {
  title: 210,
  builtInSetup: 240,
  builtInUse: 255,
  aiShortcut: 270,
  aiControl: 300,
  aiResult: 225,
  cta: 240,
};

export const TOTAL_DURATION = Object.values(SCENES).reduce((a, b) => a + b, 0);
