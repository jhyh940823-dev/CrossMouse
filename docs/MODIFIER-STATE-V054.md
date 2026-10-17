# Mac v0.5.4 — modifier state and keyboard ownership

## Confirmed defect

The old Mac event tap processed each `flagsChanged` as
`down = !pressedModifiers.contains(keyCode)`. That set existed only while
Windows was active and was emptied on return. It did not read the actual
modifier flags. A modifier pressed on Mac and released after acquisition
therefore generated a new Windows DOWN instead of an UP/no-op. With the
existing mapping, Mac Control in this sequence generated a Windows-logo DOWN.
Duplicate notifications could also invert the remembered state, and a missed
modifier release was not repaired before the next letter or click.

To test without emitting user input, that switch arm was first extracted
unchanged into `RemoteModifierState`, wired back into the actual app, and tested.
Four regression cases failed (six assertions): orphan release, duplicate
notification, missed release before paste and missed down before an ordinary
key. The local `diagnostics/modifier-red.log` records this source-level RED.
This is a deterministic defect reproduction, not a capture of the user's
physical keystrokes or proof that every reported symptom has one cause.

## Correction

The relay now reconciles the current event's modifier flags with the DOWNs it
actually sent for this input lease. Releases precede new downs and both precede
ordinary keys/clicks. Repeated snapshots are idempotent. The public Apple
IOLLEvent.h left/right masks keep both sides independent; aggregate-only
sources can use the public CG key-state table. Stale side bits without their
aggregate modifier flag never create a held key. Caps transitions send complete
presses rather than holding Caps down while its lock flag is set. Fn is not
mapped to a Windows modifier. The baseline is reset at input-lease boundaries.

Input acquisition now requires momentary keys and mouse buttons to be released.
An async edge request carries a local-input revision. A subsequent Mac key,
modifier or click invalidates queued entry, and a new local interaction during
preparation/clipboard wait cancels the matching pending acquisition. Retreating
from the Samsung seam also cancels pending input entry. Late ready messages
cannot acquire that cancelled lease. Typing does not cancel an explicit DVI
operation or an already-acquired Windows lease. Display selection is preserved.

The acquisition state source is HID hardware, not the combined session table.
A read-only live check found the hardware table clear while the session table
still had one ordinary key down (no key identity was printed). Using that
session table would have incorrectly blocked entry. Modifier snapshots still
come from each actual event; hardware-side lookup is only the fallback for
missing left/right bits. Aggregate-only synthetic/remapped sources without a
physical side keep a deterministic logical-left representation.

The Mac window explicitly labels the current keyboard/mouse destination and
the existing mapping. Shared-keyboard paste instructions now say Command+V,
which the receiver translates to Ctrl+V. The fixed mapping itself is NOT changed:
Command -> Ctrl, Control -> Windows logo, Option -> Alt, Shift -> Shift.
A Windows-layout keycap can be labelled Win even when macOS exposes it as Command;
this change does not remap the user's OS or alter their keyboard configuration.

## Scope and verification

Windows installation, live receiver, key mapping, F8, DDC, cursor rendering,
pointer speed, IP recovery, clipboard payload/policy and pairing stay unchanged.
The Windows source diff is test-only: the existing CI clipboard fixture adds
12 encrypted focus/paste/leave cycles, rejects a stale prior-lease logo-key
message, and checks native Ctrl/Alt/Shift/Win release state after each paste.
It runs only on the isolated CI runner with synthetic text and keys.

Mac tests cover the four original regressions, both sides of every shortcut
modifier, aggregate-only sources, stale device bits, release-before-paste wire
order, Caps/Fn, 500 ledger cycles and unposted CGEvent objects. Acquisition tests
cover held keys/buttons, local interaction invalidation, stale replies and DVI
preservation. Test objects are never posted to the user's desktop. No normal
keystrokes, clipboard content or passwords are logged or collected.

Runtime installation and CI observations are recorded separately below after
execution. Passing synthetic tests is not a claim that the user's physical
keyboard sequence has been observed or that arbitrary hardware remapping is fixed.

## API references

- Apple: CGEventType.flagsChanged; NSEvent.ModifierFlags; CGEventSource.keyState
- Public SDK: IOKit/hidsystem/IOLLEvent.h device modifier masks
- Microsoft: SendInput does not reset existing keyboard state
  (https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput).

## Recorded final validation — 2026-10-17

Runtime commit: `3cfdc09b08b66e2646043c597bb78e654cfcf4f9`.
Full local Swift suite: 78 tests passed, including 18 new modifier/acquisition
tests. Signed release compilation and Mac login-launch classification passed.
The Windows GUI cross-build had zero warnings/errors.

Final CI run `38995939526` completed successfully for both macOS and Windows.
The Windows log reports 12 encrypted focus/paste/leave cycles, native modifier
release checks, stale-logo-key rejection, Unicode clipboard transfer and real
Ctrl+V into its owned native text box. Existing cursor stacking, Chrome/folder
picker, native X, service lifecycle and upgrade rollback checks passed too.
The first intermediate run `38995469306` failed the unchanged Chrome CDP helper
with `KeyNotFoundException`; its new clipboard-cycle checks passed. That failure
was not hidden by disabling assertions; the final source run is recorded above.

The final signed Mac v0.5.4 was installed at the existing canonical app path.
The v0.5.3 app and preferences were backed up before graceful replacement.
The paired secret and all inspected saved settings were unchanged. The new
process stayed running and authenticated with the existing Windows v0.5.2
service at 192.168.219.108. The local UI showed input capture installed, keyboard
and mouse destination Mac, speed 37%, clipboard sharing enabled and the existing
registered login item. A screenshot of the CrossMouse control window alone was
visually inspected: the new input-destination label fits without clipping.

Windows was not reinstalled. No real user key sequence or clipboard text was
captured or posted as a diagnostic. The source/native CI regressions and live
installation/connection are verified; the user's particular intermittent
physical shortcut sequence has not been reproduced on their live PC after the
update. No claim is made that every possible shortcut/keyboard hardware issue
has been eliminated.
