# Mac v0.5.5 — keep input responsive during clipboard reads

## Report and confirmed defect

The user reported that the first Mac copy / Windows paste succeeds, but a
subsequent copy after returning to Mac can fail on both computers until some
time passes. The exact physical keyboard sequence has not been captured.

In v0.5.4, `sendPreparedEntry` synchronously called `MacTextClipboard.read` on
the main actor. `NSPasteboard.string(forType:)` may wait for another process to
provide promised clipboard data. That same main run loop services the keyboard
event tap, mouse HID observer, handoff cancellation and recovery timers. The
four-second clipboard transfer timeout was scheduled only after the native
pasteboard read returned, so it could not bound this wait.

The original reader from commit `9430fcd` was compiled into an isolated native
fixture. A child owned a uniquely named pasteboard and delayed its synthetic
text response by two seconds. The original reader blocked for 2,019.95 ms;
a main-queue callback scheduled for 50 ms ran at 2,020.02 ms. This reproduces
main-loop starvation without reading the user's general clipboard, posting
keyboard events or interacting with the running Windows receiver. It proves
the blocking path, not that every reported clipboard problem has this cause.

## Correction

Clipboard reads run in a short-lived child of the same signed executable.
The child performs AppKit access on its own main thread. Its internal entry
point runs before normal app initialization, pairing-key access, networking,
input capture and login-item setup. No second app bundle is installed.

The parent uses a bounded read deadline and can terminate its own stalled
reader. It remains able to process local input, cancellation, F8 and connection
recovery while a pasteboard owner is slow. Child output is bounded and travels
through private memory pipes; clipboard content is not placed in command-line
arguments, logs or temporary files. Failed or timed-out reads leave both
clipboards unchanged and allow the input handoff to continue.

The read stage has its own request token and current handoff ID. Returning to
Mac, a new local interaction, disabling sharing, disconnecting or quitting
cancels that stage. A delayed result cannot acquire input or send clipboard
frames for a cancelled handoff. Acknowledged change counts remain owned by the
parent and advance only after the Windows receiver confirms a successful write.
The next newly copied item is eligible immediately; no cooldown is introduced.

The existing one-way plain-text policy, excluded pasteboard types, 256 KiB
limit and encrypted wire protocol are retained. Windows-to-Mac transfer,
images and files are not added by this fix. The Windows receiver, Command/Ctrl
mapping, F8, monitor selection and pointer speed are unchanged.

## Validation boundaries

Automated clipboard tests use synthetic data and uniquely named pasteboards.
They must never call `.general` or post input to the user's applications.
Regression results and installation observations are recorded below after
execution. The user's real physical Mac/Windows round-trip remains a separate
confirmation from unit tests and the isolated native fixture.

## Recorded local validation — 2026-11-18

- Full Swift suite: **86 tests passed**, including eight new process lifecycle
  tests. The latter cover cancellation of a child that ignores SIGTERM,
  replacement, deadline expiry, EOF before process exit, bounded malformed
  output, launch failure and request identity. Test interpreter startup is not
  used as the production pasteboard performance measurement.
- The signed release app passed strict code-signature verification and the
  existing login/background launch self-test without registration changes.
- `scripts/test-clipboard-responsiveness.sh` ran against that actual signed
  release executable, using only uniquely named synthetic pasteboards:

| Native integration case | Observed result |
| --- | --- |
| Two-second data provider, main callback scheduled at 50 ms | 50.64 ms |
| Same provider, one-second read deadline | 1,001.09 ms; no late result |
| Cancel after provider request, immediately read fresh text | 22.86 ms; no cancelled callback |
| Twenty different Unicode copies followed by acknowledged unchanged result | 276.98 ms total |
| Exact 256 KiB / over-limit text | Preserved / rejected |
| Five protected or file markers | Excluded |
| Child-process cleanup | All owned helper children reaped |

These twenty cycles exercise the production reader subprocess and native
pasteboard API, not twenty physical Mac/Windows cursor crossings or Windows
paste commands. The Windows wire payload and receiver source did not change.

## Primary API contracts

- [Apple NSPasteboard.string(forType:)](https://developer.apple.com/documentation/appkit/nspasteboard/string(fortype:)) calls `data(forType:)`.
- [Apple NSPasteboard.data(forType:)](https://developer.apple.com/documentation/appkit/nspasteboard/data(fortype:)) documents slow-owner IPC timeouts and communication exceptions.
- Swift task cancellation cannot interrupt an already-running synchronous native call; process isolation supplies the cancellation boundary here.
