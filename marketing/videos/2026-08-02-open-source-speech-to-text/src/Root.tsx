import React from "react";
import { Composition, Series, Still } from "remotion";
import {
  BuildScene,
  CtaScene,
  LicenseScene,
  OfflineCloudScene,
  PrivacyScene,
  PublicRepoScene,
  Thumbnail,
  TitleScene,
} from "./scenes";
import { FPS, SCENES, TOTAL_DURATION } from "./theme";

const OpenSourceSpeechToText: React.FC = () => (
  <Series>
    <Series.Sequence durationInFrames={SCENES.title}><TitleScene /></Series.Sequence>
    <Series.Sequence durationInFrames={SCENES.publicRepo}><PublicRepoScene /></Series.Sequence>
    <Series.Sequence durationInFrames={SCENES.license}><LicenseScene /></Series.Sequence>
    <Series.Sequence durationInFrames={SCENES.build}><BuildScene /></Series.Sequence>
    <Series.Sequence durationInFrames={SCENES.offlineCloud}><OfflineCloudScene /></Series.Sequence>
    <Series.Sequence durationInFrames={SCENES.privacy}><PrivacyScene /></Series.Sequence>
    <Series.Sequence durationInFrames={SCENES.cta}><CtaScene /></Series.Sequence>
  </Series>
);

export const RemotionRoot: React.FC = () => (
  <>
    <Composition
      id="OpenSourceSpeechToText"
      component={OpenSourceSpeechToText}
      durationInFrames={TOTAL_DURATION}
      fps={FPS}
      width={1920}
      height={1080}
    />
    <Still
      id="OpenSourceSpeechToTextThumbnail"
      component={Thumbnail}
      width={1920}
      height={1080}
    />
  </>
);
