# Android overlay: bubble and selection-command button states

The Android accessibility overlay consists of three windows:

- the **bubble** (`OverlayMicButtonView`): the speak button, draggable, shown while an
  editable field is focused;
- the **command buttons**: *Fix grammar* and *Rewrite with AI*, shown beside the bubble
  while the focused field has a selection;
- the **dismiss zones** shown only while the bubble is being dragged.

`OverlayDictationAccessibilityService` owns the state. The pure functions at the top
of that file (`resolveBubblePresentation`, `shouldShowCommandActions`,
`canStartSelectionCommand`, `deliveryKeepsBubbleBusy`) encode the invariants below and
are covered by `OverlayRecordingPresentationTest`.

## Bubble presentations

| Presentation | When | Look |
| --- | --- | --- |
| Idle | `recordingState == Idle` | 55 dp circle with the frozen waveform glyph |
| Recording | `recordingState == Recording` (dictation or rewrite instruction) | 250 dp pill: cancel (X), live waveform, accept (check) |
| Processing | `recordingState == Processing`, no active command | 250 dp pill: animated bars and a spinner |
| CommandProcessing | `recordingState == Processing`, a command is active | 250 dp pill: indeterminate progress bar, the command's icon where the speak button was |

While a pressed command button is sliding into the bubble the bubble keeps the Idle look
regardless of the logical state, so the button visibly lands on the speak button before
the bubble morphs.

## Command button invariants

1. **Shown or absent, never disabled.** The buttons appear only when they can be tapped:
   bubble idle, no dictation delivery in flight, and a non-blank selection in the focused
   field. There is no dimmed, disabled, or highlighted button state.
2. **Both buttons leave together.** When either is pressed, a copy of the pressed button
   slides into the bubble's position and the real buttons are removed. The other button
   never stays behind.
3. **Only one command at a time.** A second press, or a bubble tap, is ignored while a
   command is active. The bubble is not tappable for dictation until the command finishes.
4. **The pressed button becomes the speak button.** After the slide the bubble shows the
   command's icon in the speak button's circle with a progress bar beside it. For
   *Fix grammar* this happens immediately. For *Rewrite with AI* the bubble first records
   the instruction (same controls as dictation) and shows the icon and progress bar after
   the instruction is accepted.
5. **Busy until applied.** A rewrite keeps the icon and progress bar through instruction
   transcription, the rewrite request, and applying the text. Only dictation hands the
   bubble back early so a new dictation can replace a pending insertion.
6. **Return to the pre-press state.** When a command finishes, fails, or is cancelled
   (cancel tap during rewrite recording, field closed, bubble hidden), the bubble returns to
   Idle and the buttons fade back in if a selection is still present. After a successful
   replacement the selection collapses, so the buttons stay hidden.
7. **Hidden while the bubble is busy for dictation.** A dictation started from the bubble
   hides the buttons even if a selection exists, and they stay hidden while the dictated
   text is being inserted.
8. **Follow the bubble.** While visible the buttons sit beside the bubble, on the side
   with room, and move with it when it is dragged. Dragging the bubble to the dismiss zones
   hides them.
9. **One accent colour.** The bubble, the buttons, and the sliding copy share the colour
   from the bubble colour preference; changing the preference restyles all of them.
10. **Accessibility.** The bubble is hidden from accessibility services, so the transitions
    are announced: "Fixing grammar", "Listening for rewrite instructions", and "Rewriting
    selected text".
