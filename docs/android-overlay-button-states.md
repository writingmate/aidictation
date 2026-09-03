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
| Idle | `recordingState == Idle` | 55 dp themed-white circle with the themed-black waveform glyph |
| Recording | `recordingState == Recording` | 250 dp pill: cancel (X), live waveform, accept (check), same palette |
| Processing | `recordingState == Processing` | 250 dp pill: animated bars and a spinner, same palette |

**Palette.** The bubble is drawn on the theme's surface (white in light mode, the dark
surface in dark mode) with glyphs in the theme's black (opaque on-surface). The pill and
cancel circle are that surface tinted 10% with the glyph colour. The wand and the panel
use the same neutrals; there is no colour preference.

**Translucency and shadow.** Every floating button (the bubble in all three states and
the wand) is filled at 90% opacity so the field underneath shows through faintly; glyphs
stay opaque. Both sit on a standard 6 dp elevation shadow. The bubble view keeps a 6 dp
transparent margin on every side of the drawn surface (its window is 67 dp tall) so the
shadow is not clipped by the window edge. Its outline follows the drawn surfaces: the
idle circle alone, or while recording the cancel (X) circle, the waveform pill and the
accept circle each with their own shadow (on Android 10 and later; earlier releases only
allow a convex outline, so one rounded shape spans all three). The buttons inside the
edit panel stay flat on the panel surface. The idle waveform logo is drawn at 90% of its
former size inside the circle. Windows sit 8 dp from the screen edge and the keyboard,
which with the margin puts the visible circle about 18 dp in.

The bubble takes no part in text editing: selection commands live entirely in the
wand and its panel.

**Visibility.** The bubble shows while an editable field has input focus and the
keyboard is up. When the keyboard closes it leaves after a short debounce, unless
dictation is recording, processing or delivering, or the edit panel is open. The
sticky-focus fallback that bridges WebView tree rebuilds applies only while the keyboard
is still up; a closed keyboard or a password field ends it (`bubbleNeedsKeyboard`).

**Keyboard signal.** Two sources, in order of preference:

1. `KeyboardProbeWindow`: when "display over other apps" is granted, the service keeps
   a hidden 1 px-wide, full-height application overlay window. The window manager
   resizes it above the keyboard and (Android 11+) dispatches the keyboard insets to
   it, so keyboard show, hide and top edge arrive as layout events with no polling and
   no accessibility round trips. The probe's reports are used only once it has seen the
   keyboard at least once on the device, so it can never make things worse than the
   fallback. Hides then use the normal 250 ms debounce.
2. The accessibility window list: an input-method window with non-empty bounds counts
   as a keyboard. Keyboards are never active or focused windows and many expose no
   accessibility tree (incognito and password modes, floating layouts, some third-party
   keyboards), so nothing beyond the bounds is checked. An input-method window
   appearing or disappearing is handled immediately rather than in the coalesced pass.
   Because this list flaps during keyboard animations, hides on this path wait a
   700 ms grace period.

The permission is optional: onboarding asks for it on its last step and Settings >
Permissions shows its state.

## Wand button invariants

1. **Shown or absent, never disabled.** The wand appears only when it can be tapped:
   bubble idle, no dictation delivery in flight, a non-blank selection in the focused
   field, and no panel open.
2. **Borderless secondary button.** Themed surface fill (white in a light theme) at the
   same 90% opacity as the bubble, the themed-black wand icon and the standard 6 dp
   shadow. Pressed state layer 12%.
3. **Follows the bubble.** It sits on the side of the bubble with room and moves with
   it when dragged. Dragging the bubble to the dismiss zones hides it.
4. **Absorbed by the panel.** Tapping it swells and fades the wand while the panel
   blooms out of its centre. It reappears when the panel closes if a selection remains,
   and never while the panel's window is still on screen (the close and apply
   animations included), so it cannot stack on top of the panel.
5. **Always below the panel, above the bubble.** Overlay windows stack in the order
   they are added. Whenever the bubble's window is re-added (its size changes with the
   recording state) the wand and the panel are re-added after it.

## Rewrite panel invariants

1. **Layout.** The working text on top, full width, up to six lines with scrolling. One
   row below: the action icons (Fix grammar, Rephrase, Shorter, Longer) on the left,
   close (×) and apply (✓) on the right. No label, no inner card.
2. **Styles.** Material emphasis levels: apply and the running action are filled with
   the theme's black (opaque on-surface: near-black in light, light in dark) and a
   surface-coloured icon; every other button is a borderless secondary button (surface
   fill, themed-black icon). The progress bar is themed black too.
   Disabled content sits at 38%, pressed state layer at 12%. The panel surface is the
   theme's floating background.
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
10. **Theme neutrals only.** The bubble, the wand and the panel are drawn in the theme's
    surface and black. There is no bubble colour preference any more.
11. **Light and dark.** Surface, text and outline come from the app's XML theme, which
    has a night variant (`values-night/themes.xml`), so the panel and wand follow the
    system dark mode. A panel that is already open keeps its colours until reopened.
12. **Accessibility.** The panel's buttons are ordinary focusable controls with labels.
    Panel open, action start and text updates are announced.

## Event handling cost

The service runs on the app's main thread, and every overlay refresh makes synchronous
round trips into the focused app (input-focus lookups, window roots). Only direct user
interaction events (focus, click, selection change) are handled immediately; window and
content change events are coalesced into one refresh per 120 ms burst. Each refresh
resolves the focused field once, tries the active window before fetching the root of
every other window, and skips system and overlay windows.
