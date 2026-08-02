import React from "react";
import { Composition, Series, Still } from "remotion";
import {
  AiControlScene,
  AiResultScene,
  AiShortcutScene,
  BuiltInSetupScene,
  BuiltInUseScene,
  CtaScene,
  Thumbnail,
  TitleScene,
} from "./scenes";
import { FPS, SCENES, TOTAL_DURATION } from "./theme";

const MacDictationGuide: React.FC = () => (
  <Series>
    <Series.Sequence durationInFrames={SCENES.title}><TitleScene /></Series.Sequence>
    <Series.Sequence durationInFrames={SCENES.builtInSetup}><BuiltInSetupScene /></Series.Sequence>
    <Series.Sequence durationInFrames={SCENES.builtInUse}><BuiltInUseScene /></Series.Sequence>
    <Series.Sequence durationInFrames={SCENES.aiShortcut}><AiShortcutScene /></Series.Sequence>
    <Series.Sequence durationInFrames={SCENES.aiControl}><AiControlScene /></Series.Sequence>
    <Series.Sequence durationInFrames={SCENES.aiResult}><AiResultScene /></Series.Sequence>
    <Series.Sequence durationInFrames={SCENES.cta}><CtaScene /></Series.Sequence>
  </Series>
);

export const RemotionRoot: React.FC = () => (
  <>
    <Composition
      id="MacDictationGuide"
      component={MacDictationGuide}
      durationInFrames={TOTAL_DURATION}
      fps={FPS}
      width={1920}
      height={1080}
    />
    <Still id="MacDictationThumbnail" component={Thumbnail} width={1920} height={1080} />
  </>
);
