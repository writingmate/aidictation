# AIDictation v0.0.106

## Faster

- Dictation feels roughly 6 seconds quicker end to end. Most of it was the
  app being throttled by macOS App Nap while it ran in the background during
  a recording — the work was queued and simply never scheduled.
- The recording bubble now appears the instant you press the key, instead of
  about two seconds later.
- The transcript pastes as soon as it arrives; usage accounting no longer
  holds it up.
- Audio uploads are about a quarter the size, and the connection is opened
  while you are still speaking.

## Fixed

- Silence is no longer sent for transcription. A brief click or breath could
  be read as speech, and an empty recording would come back as "Thank you."
- Recordings with no speech now say so, instead of ending with nothing.
- The overlay no longer draws two overlapping pills mid-animation, and no
  longer follows the screen it was previously on.

## New

- A short thump when recording starts and stops, with a toggle in
  Settings under Overlay Settings.
