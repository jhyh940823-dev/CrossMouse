# Reliability resume — 2026-10-11

This continues the preserved `66ba878` work without resetting the interrupted
local worktree. The user-approved behavior remains: HDMI stays selected while
the cursor crosses between Samsung/Mac and Philips/Windows; only F8/play-pause
or the explicit DVI button changes Philips back. Saved pointer speed is retained.

## Cursor rendering: the missing default-path check

The earlier Chrome integration passed `simulateHiddenNativePointerForTest=true`.
That bypassed the real decision which hid CrossMouse's cursor surface whenever
Windows reported both `MousePresent` and `CURSOR_SHOWING`. Neither is a measured
pixel on the user's monitor. A successful forced-fallback test could therefore
not establish the production cursor lifecycle.

Test-only commit `fd9821e` removed that forcing parameter and crossed the real
Chrome hand/text/resize/hidden/text/hand controls. Run `38100943515` failed with
`No readable pointer pixel change (0): chrome-hand-light.png`. This establishes
that our surface was absent on the ordinary path; it is not a hardware trace
of the user's particular invisible-cursor event or proof of a native cursor's
absence on the CI host.

In `6ff9da8`, a remote input lease owns its pointer surface continuously.
Windows still supplies its position, shape and hotspot. Leaving an application
or changing glyph never hands presentation off to a visibility flag. Returning
input hides the surface. A failure is observable and releases control rather
than leaving a receiver claiming to control an invisible pointer. A new lease
may retry a failed surface; render ticks do not spawn endless retry threads.
No global ShowCursor count, mouse scheme or unrelated application's settings
are modified. A local/native pointer may coincide with the owned surface;
this design intentionally prioritizes an always-drawn remote pointer.

The same default-constructor Chrome test passed in run `38101500217`, including
the native folder picker and click-through. The cursor crop evidence was also
visually inspected: light/dark I-beams, a hand and the folder-dialog arrow.
This is not merely a color-change fix. Alpha/XOR rasterization from the earlier
branch is retained, but the production display-ownership decision is replaced.

## Input, desktop and failure boundaries

- The source-timed motion timeline conserves distance, bounds backlog and drains
  preceding motion before clicks. Synthetic 8–32 ms delivery jitter is tested;
  no claim is made to eliminate arbitrary Wi-Fi loss or to prove user-device feel.
- The authenticated peer gets a five-second silence lease, renewed only after
  complete verified frames. A stationary mouse with heartbeats remains active.
  A silent open socket or partial frame loses ownership and its listener slot.
- The service test now acquires input on the original desktop, switches to an
  isolated desktop and back while the SAME input lease stays active, and checks
  the newly painted surface name, click and keyboard delivery. It does not log
  off, reboot, type a password, approve a UAC prompt or disable secure desktop.
- F8 fresh-down recovery handles a missing prior release. The actual event-tap
  decoder includes F8 and play/pause. On the Mac, the installed build accepted a
  tagged synthetic F8 while the panel state was unknown and the peer disconnected;
  its bounded journal recorded the DVI request and completion. This is not a
  claim that a physical keyboard was pressed during that test.
  A last-run DVI preference is now explicitly unconfirmed until a current read
  or selection occurs; it cannot silently disable the recovery key after restart.
- Mac diagnostics show the authenticated Windows version, service/ordinary app
  mode and desktop/pointer state. Ordinary keyboard events, passwords, pairing
  keys and user window titles are not recorded.

## Installation and remaining physical validation

`Install-CrossMouse-Service.cmd` builds the source with the Windows SDK already
installed, requests explicit service-install confirmation, then requests Windows
administrator approval. The protected service is placed at
`C:\Program Files\CrossMouse\CrossMouse.exe`, reuses the existing pairing key,
and adds a program-specific local-subnet firewall rule. Granting this permission lets
the paired Mac control sign-in/secure-desktop input; it is a privileged feature,
not merely ordinary login auto-start. It does not remove the Windows password,
turn on automatic login, disable UAC/antivirus, or implement arbitrary commands.

Upgrades take a protected backup before stopping a working service. Conflicting
service/rule owners are rejected. Firewall and opt-in login registration are
published after agent readiness. An injected failed upgrade is used to verify
binary/config restoration and a working authenticated agent, not just file copies.
The installer is exercised by inbox Windows PowerShell, as the launcher uses.

Mac v0.5.0 was installed at the existing canonical path after backing up v0.4.3
and its preferences. The pairing key was unchanged; saved speed 37% and the
registered login item were observed afterward. The Windows receiver was not connected
during this local check. Windows service installation, physical Chrome/UAC
visibility and real post-reboot PIN sign-in remain user-machine validation.
BitLocker/firmware pre-boot screens and secure-attention Ctrl+Alt+Delete are not
implemented by a Windows user-session input service. The Mac must already be
logged in and both machines must have network connectivity.

## Final recorded validation

Runtime/installer commit: `58f56ffd9c6498d6e9934c94e886f38e7ba5d696`.
Windows and Mac CI run: `38102632399` (both jobs succeeded).

- 47 Swift tests passed locally and on macOS CI, including F8 release-loss and
  stale saved-DVI state. The existing encrypted protocol vectors still pass.
- The default-path Chrome glyph transitions and real native folder-picker
  surface/click-through checks passed, with no forced-fallback switch.
- Inbox Windows PowerShell executed first service installation, live desktop
  transitions, a deliberately failed upgrade, rollback and a second successful
  encrypted input/desktop check. Service stop left no owned agent alive.
- The Windows cadence sample measured mean 8.15 ms / p95 8.55 ms for the shared
  clock. This is a CI measurement, not the user's screen FPS or wireless latency.
- Existing X-to-tray, idle entry, repeated handoff and protected pairing checks
  remained green. Original v0.4.3 Mac and preference backups remain on the Mac.

The final Mac v0.5.0 was restarted with the saved DVI preference present and an
unreadable hardware input value. A tagged F8 was consumed and its DVI completion
was observed; the UI retained 37% speed and an enabled login item. Windows was
still shown as connection-waiting, so physical Windows cursor/PIN/UAC success is
not claimed by this local observation.
