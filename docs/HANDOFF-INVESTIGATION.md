# Automatic handoff investigation and replacement contract

## Observed, not inferred

- The user reports real DVI/HDMI test buttons succeed, while automatic entry can return immediately or show no Windows cursor.
- The running Mac v0.3.7 menu recorded `Windows requested return to Mac`; that protocol contains no cause or transaction ID, so it cannot identify which Windows action caused the user's prior return.
- A controlled live test on 2026-10-10 triggered the existing hot corner without injected movement. Its state changed to `Windows confirmed remote control` after about 4.4 s and stayed there for the remainder of a 16 s trace. A deliberate negative movement was used to return afterward. This attempt did **not** reproduce the user's immediate return, nor did a Mac-side status prove that a physical Windows cursor was visible.
- A separate ping-only Python schema probe could not connect from its execution environment. The actual CrossMouse connection was responsive. That probe is inconclusive, not proof of a firewall/router problem.

## Confirmed contract defects in 1097660

1. `tickHotCorner` treated a fixed 1.5 s / 0.4 s quiet interval as readiness. `enterWindowsAfterHotCorner` set local `remoteActive` before receiving `entered`.
2. `InputInjector` used the bounding box of all Windows displays. `SetCursorPos` / `SendInput` succeeding was accepted as readiness without observing pointer presentation on the intended display.
3. Every untagged `leave` could trigger DVI while `autoEnteredFromPhilips` was set. No request ID or return reason distinguished a stale response, actual left-edge movement, or window close.
4. A basic `pong` could not distinguish a compatible automatic receiver from an older executable. A newer Mac was allowed to proceed with unverified endpoint semantics.

These are reproducible software design errors. They do not establish which of these (or a driver-specific effect) triggered every reported physical failure. That distinction must remain explicit.

## Replacement: one correlated ownership transaction

`local -> preparing(id) -> switchingToWindows(id) -> acquiring(id) -> windows(id) -> switchingToMac(id) -> local`

- Receiver advertises `handoff-2` and actual executable version in its encrypted heartbeat. Unsupported peers keep existing manual sharing; automatic video changes are not attempted against them.
- Prepare resolves an individual Philips display (or the only Windows display), wakes its pointer path, and replies with the same ID. Preparing does not accept user input.
- Mac sends the HDMI command only after preparation. Completion triggers `enter(id)`, not local input capture. The old time-based readiness gate is removed.
- Receiver re-resolves the target after the video command (the preparation handle/bounds may have changed), reads current monitor input when available, places the pointer on that display, and verifies a presentation path. Native cursor absence uses a non-activating, click-through pointer surface, not global ShowCursor counter changes. Unsupported VCP reads are reported as `input-read-unavailable`, **not** HDMI verification.
- Only `entered(id, pointerVisible=true)` lets the Mac capture input. All automatic input retains that ID, including coalesced movement.
- Only a matching `leave(id, reason=left-edge/window-close)` can request automatic DVI return. Old, missing and unrelated IDs cannot move/release a newer owner. Cancellation invalidates subsequent callbacks. Deadline expiry releases local input; time passage never grants ownership.
- The settings UI and receiver remain on independent threads; the existing real native-titlebar-X regression remains required.

## Validation and limits

Core tests exercise exact event order, cancellation, stale replies, visible-presentation acknowledgement, encrypted metadata, and idle ownership. Windows regression uses a real temporary TCP receiver to exercise prepare/acquire/idle/stale input/intentional return. A simulated absent native cursor exercises the real passive presentation window and verifies no focus change.

The Windows CI runner is not the user's physical Philips monitor. DDC writes are not made in CI. VCP input read may be unavailable, and no API here proves that a physical panel finished scanning out. Actual user-side native/hardware cursor visibility remains a separate observation. Changes are kept on `fix/handoff-ownership` until these distinctions and integration results are reviewed; a compiler or CI pass alone must not be announced as a physical-device fix.

No pairing secrets, clipboard contents, user key presses, or user files are logged. Transaction diagnostics record only IDs, phases, reasons, and software version. Live diagnostics are excluded from git.

References: Microsoft `SetCursorPos`, `GetCursorInfo`, `ShowCursor`, and `GetVCPFeatureAndVCPFeatureReply`; Apple `CGWarpMouseCursorPosition`. See official documentation for the distinction between position, injected input, visible cursor, and display-source replies.
