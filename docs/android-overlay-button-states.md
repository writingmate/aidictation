# Android overlay: bubble, wand button and rewrite panel

The Android accessibility overlay consists of four windows:

- the **bubble** (`OverlayMicButtonView`): the speak button, draggable, shown while an
  editable field is focused;
- the **wand button**: a single "Edit with AI" button shown beside the bubble while the
  focused field has a selection;
- the **rewrite panel** (`OverlayRewritePanelView`): opened from the wand, shown just
  above the keyboard, stacked above the bubble;
- the **dismiss zones** shown only while the bubble is being dragged.

`OverlayDictationAccessibilityService` owns the state. The pure functions at the top
of that file (`canStartSelectionCommand`, `shouldShowWandButton`) encode the visibility
invariants and are covered by `OverlayRecordingPresentationTest`.

## Bubble presentations

| Presentation | When | Look |
| --- | --- | --- |
| Idle | `recordingState == Idle` | 55 dp circle with the frozen waveform glyph |
| Recording | `recordingState == Recording` | 250 dp pill: cancel (X), live waveform, accept (check) |
| Processing | `recordingState == Processing` | 250 dp pill: animated bars and a spinner |

The bubble takes no part in text editing: selection commands live entirely in the
wand and its panel.

## Wand button invariants

1. **Shown or absent, never disabled.** The wand appears only when it can be tapped:
   bubble idle, no dictation delivery in flight, a non-blank selection in the focused
   field, and no panel open.
2. **Solid-border style.** Surface fill (white in a light theme), a 1.5 dp accent
   stroke and the accent wand icon, so it reads as subordinate to the solid bubble.
3. **Follows the bubble.** It sits on the side of the bubble with room and moves with
   it when dragged. Dragging the bubble to the dismiss zones hides it.
4. **Absorbed by the panel.** Tapping it swells and fades the wand while the panel
   blooms out of its centre. It reappears when the panel closes if a selection remains.

## Rewrite panel invariants

1. **Layout.** The working text on top, full width, up to six lines with scrolling. One
   row below: the action icons (Fix grammar, Rephrase, Shorter, Longer) on the left,
   close (×) and apply (✓) on the right. No label, no inner card.
2. **Styles.** Apply and the running action are filled accent. Every other button uses
   the solid-border style. The panel surface is the theme's floating background.
3. **Bloom.** Opening scales the panel up from the wand's centre with a small overshoot
   while its corners round off, the text rises in, then the icons pop in one after
   another, × and ✓ last. Closing withers the panel back towards the wand. Applying
   settles it down towards the field and fades.
4. **Working text, not the field.** Actions transform the panel's working copy and
   chain on the current text. Nothing is written to the field until ✓.
5. **One action at a time.** While an action runs its icon is filled and pulses, a thin
   progress bar sweeps along the top edge, the text dims, and the other actions and ✓
   are disabled. × still works and cancels the request.
6. **Results land visibly.** The new text cross-fades over the old and the icon nods.
   A failed action leaves the text unchanged and shows a toast.
7. **Apply replaces the original selection.** ✓ writes the working text over the
   originally selected text (the current selection, else its last occurrence in the
   field) and collapses the caret after it. Applying unchanged text simply closes.
8. **Ignoring is free.** The bubble stays idle and usable while the panel is open.
   Starting dictation from the bubble, the field losing focus (bubble hides), or the
   service stopping discards the panel without changing text. × does the same with the
   wither animation.
9. **Follows the keyboard.** The panel sits above the keyboard and repositions when the
   keyboard shows or hides.
10. **One accent colour.** The bubble, the wand and the panel share the colour from the
    bubble colour preference; changing the preference restyles all of them.
11. **Accessibility.** The panel's buttons are ordinary focusable controls with labels.
    Panel open, action start and text updates are announced.

## Event handling cost

The service runs on the app's main thread, and every overlay refresh makes synchronous
round trips into the focused app (input-focus lookups, window roots). Only direct user
interaction events (focus, click, selection change) are handled immediately; window and
content change events are coalesced into one refresh per 120 ms burst. Each refresh
resolves the focused field once, tries the active window before fetching the root of
every other window, and skips system and overlay windows.
