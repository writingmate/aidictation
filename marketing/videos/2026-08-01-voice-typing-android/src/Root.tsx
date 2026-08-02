import React from "react";
import { Composition, Series, Still } from "remotion";
import {
  CtaScene,
  CustomizeScene,
  DictateScene,
  FocusScene,
  ModesScene,
  PermissionsScene,
  Thumbnail,
  TitleScene,
} from "./scenes";
import { FPS, SCENES, TOTAL_DURATION } from "./theme";

const VoiceTypingAndroid: React.FC = () => (
  <Series>
    <Series.Sequence durationInFrames={SCENES.title}><TitleScene /></Series.Sequence>
    <Series.Sequence durationInFrames={SCENES.permissions}><PermissionsScene /></Series.Sequence>
    <Series.Sequence durationInFrames={SCENES.focus}><FocusScene /></Series.Sequence>
    <Series.Sequence durationInFrames={SCENES.dictate}><DictateScene /></Series.Sequence>
    <Series.Sequence durationInFrames={SCENES.modes}><ModesScene /></Series.Sequence>
    <Series.Sequence durationInFrames={SCENES.customize}><CustomizeScene /></Series.Sequence>
    <Series.Sequence durationInFrames={SCENES.cta}><CtaScene /></Series.Sequence>
  </Series>
);

export const RemotionRoot: React.FC = () => (
  <>
    <Composition
      id="VoiceTypingAndroid"
      component={VoiceTypingAndroid}
      durationInFrames={TOTAL_DURATION}
      fps={FPS}
      width={1920}
      height={1080}
    />
    <Still
      id="VoiceTypingAndroidThumbnail"
      component={Thumbnail}
      width={1920}
      height={1080}
    />
  </>
);
