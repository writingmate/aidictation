# Android overlay: bubble and selection-command button states

The Android accessibility overlay consists of four windows:

- the **bubble** (`OverlayMicButtonView`): the speak button, draggable, shown while an
  editable field is focused;
- the **command buttons**: *Fix grammar* and *Rewrite with AI*, shown beside the bubble
  while the focused field has a selection, drawn in the bubble's secondary (translucent
  accent) colour with an accent icon;
- the **review card**: a command result waiting to be accepted or dismissed, shown just
  above the keyboard;
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
5. **Busy until the suggestion is ready.** A rewrite keeps the icon and progress bar
   through instruction transcription and the rewrite request. Only dictation hands the
   bubble back early so a new dictation can replace a pending insertion.
6. **Nothing is replaced without review.** A command result is shown on the review card
   with deletions struck through and insertions in bold accent. *Accept* replaces the
   originally selected text (the current selection, else its last occurrence in the
   field). *Dismiss* discards it. A result identical to the original shows a toast
   instead of a card.
7. **Ignoring a suggestion is free.** The bubble is idle while the card is showing. The
   card is discarded, without changing text, when the user starts dictation from the
   bubble, when the field loses focus and the bubble hides, or when the service stops.
   The command buttons stay hidden while a review is pending, so only one suggestion
   exists at a time.
8. **Return to the pre-press state.** When a command fails or is cancelled (cancel tap
   during rewrite recording, field closed, bubble hidden), or a review is dismissed, the
   bubble is Idle and the buttons fade back in if a selection is still present. After an
   accepted replacement the selection collapses, so the buttons stay hidden.
9. **Hidden while the bubble is busy for dictation.** A dictation started from the bubble
   hides the buttons even if a selection exists, and they stay hidden while the dictated
   text is being inserted.
10. **Follow the bubble and the keyboard.** While visible the buttons sit beside the
    bubble, on the side with room, and move with it when it is dragged. Dragging the
    bubble to the dismiss zones hides them. The review card sits above the keyboard and
    follows it.
11. **One accent colour.** The bubble, the buttons, the sliding copy and the review card
    share the colour from the bubble colour preference; changing the preference restyles
    all of them.
12. **Accessibility.** The bubble is hidden from accessibility services, so the transitions
    are announced: "Fixing grammar", "Listening for rewrite instructions", "Rewriting
    selected text" and "Review the suggested changes". The card's buttons are ordinary
    focusable controls.

## Event handling cost

The service runs on the app's main thread, and every overlay refresh makes synchronous
round trips into the focused app (input-focus lookups, window roots). Only direct user
interaction events (focus, click, selection change) are handled immediately; window and
content change events are coalesced into one refresh per 120 ms burst. Each refresh
resolves the focused field once, tries the active window before fetching the root of
every other window, and skips system and overlay windows.
