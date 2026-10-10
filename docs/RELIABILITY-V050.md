# v0.5.0 investigation and integration candidate

This development branch is not proof of a physical-PC fix. The running user's
Mac v0.4.3 and their Windows receiver have not been replaced during this work.

## Failures and boundaries

* A lost release of F8/play-pause leaves the old shortcut latch set forever.
  `ReliabilityRegressionTests.testLostF8ReleaseCannotDisableFuturePressesForever`
  fails twice on the unchanged implementation (both representations). Fresh
  non-repeat presses now begin a new press; repeat suppression remains local to
  that press. DDC transaction idempotence is not implemented by latching a key.
* Restarting a process never changes the Philips input, but the old state started
  as DVI unconditionally. The app now starts with unknown video state, attempts a
  read, and permits deliberate F8 recovery while unknown. It does not fabricate a
  successful physical switch. DDC helpers have a bounded lifetime and cannot
  leave the app waiting forever for EOF from a hung process.
* A color-key Form cannot reproduce arbitrary alpha/AND/XOR cursor resources.
  The candidate reconstructs premultiplied cursor pixels with the actual resource
  dimensions/hotspot, uses an alpha layered surface, and owns copied resources.
  Inversion glyphs get a contrast rim; genuinely empty or null cursors get a
  visible fallback. The ordinary desktop and Winlogon are different desktops.
* SendInput return values were ignored for clicks and keys. The receiver must
  either inject on its authorized input desktop or explicitly relinquish input;
  an unelevated process does not gain secure-desktop authority from cursor drawing.
* A packet-size-dependent geometric smoother does not preserve constant frame
  velocity for constant source movement. Source timestamps now drive a bounded
  linear playout timeline. It preserves total distance and click ordering without
  predicting future movement; long network stalls can still be visible.

## Privileged component is opt-in

`scripts/Install-Windows.ps1 -InstallService` builds first, then asks for Windows
administrator approval. A fixed Program Files executable runs a session-zero
broker with no network listener or interactive UI. It launches only its own fixed
session-agent mode in the physical console session. The agent authenticates the
paired Mac and binds window-free input workers to the current input desktop.
Each pointer surface is created on its desktop rather than moving a window to a
new desktop. Credentials, ordinary key values and screenshots are not logged.

The service grants the paired Mac elevated input capability, including sign-in
and administrator prompts. Protect both machines and the pairing key accordingly.
It does not type passwords automatically, weaken UAC, change network profiles or
disable antivirus. The explicit installer adds one program/port/local-subnet
firewall rule and copies the existing pairing key into SYSTEM/administrator-only
storage. Local TCP self-connections are rejected in production service mode.
The local control pipe is restricted to the installing user and can only release
input; it cannot execute commands, inject keys, or read pairing secrets.

The normal settings UI does not run as SYSTEM and does not start a duplicate
receiver when the service is installed. Stopping the service requires administrator
approval. Existing login registration is updated only if it was already enabled.
Uninstall removes the service/rule and preserves key/binary backups.

## Required validation

Mac unit tests, real cursor-raster fixtures, source/arrival-timing replay,
native-titlebar X, bounded rendering dispatch, input ownership and hidden-start
regressions must pass. Windows CI additionally installs an isolated test service,
checks its key ACL and physical-console agent, then verifies authenticated input on
a separate test desktop and restores the original desktop in cleanup. That is not
the user's actual PIN screen, physical dongle, or Philips panel.

Official API constraints: [SendInput](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput),
[SetThreadDesktop](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setthreaddesktop),
[DrawIconEx](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-drawiconex),
[UpdateLayeredWindow](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-updatelayeredwindow).
