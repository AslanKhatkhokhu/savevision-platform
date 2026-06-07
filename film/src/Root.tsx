import React from "react";
import { Composition } from "remotion";
import { SaveVisionFilm } from "./Film";

// 85s at 30fps. Two formats: landscape (sponsors) + vertical (social).
const FPS = 30;
const DUR = 2550;

export const RemotionRoot: React.FC = () => {
  return (
    <>
      <Composition
        id="SaveVision"
        component={SaveVisionFilm}
        durationInFrames={DUR}
        fps={FPS}
        width={1920}
        height={1080}
      />
      <Composition
        id="SaveVisionVertical"
        component={SaveVisionFilm}
        durationInFrames={DUR}
        fps={FPS}
        width={1080}
        height={1920}
      />
    </>
  );
};
