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
  output, launch failure and request identity. Native lifecycle fixtures compile
  before the measured deadline; no interpreter startup is part of that budget.
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

## CI and installed application

Runtime source: `3d3d8812d88ded955e9783926f4306b4a96264dc`.
CI run [44251086797](https://github.com/jhyh940823-dev/CrossMouse/actions/runs/44251086797)
passed both macOS and Windows jobs. The macOS runner passed all 86 tests and
ran the actual release helper against the delayed native pasteboard provider:
the 50 ms main callback ran at 50.79 ms, timeout completed at 1,012.59 ms, and
the fresh read after cancellation completed in 17.51 ms. All native integration
cases, including bounded output and child cleanup, passed.

The initial CI run `44249958791` failed three process-lifecycle tests that used
Python fixtures. Those fixtures were replaced with native children compiled
before the deadline, retaining the existing assertions and time budgets and
adding an explicit old-child PID disappearance check. The production reader
coordinator was unchanged by that replacement. The final native CI comparison
passed; the initial interpreter-specific failure was not asserted to prove a
production cancellation defect or a particular Python startup cause. The
workflow now runs the independent native integration even if a unit test fails,
while retaining a failed job outcome when any required check fails.

The signed v0.5.5 app was installed at the existing canonical Mac path after a
CRC- and binary-hash-verified v0.5.4 archive and preferences backup. The original
process exited normally before replacement. The running v0.5.5 binary hash and
code signature were verified after launch. Its control window reported paired
authentication and normal responses from the existing Windows v0.5.2 service,
installed input capture, clipboard sharing enabled, 37% pointer speed, automatic
monitor switching enabled and the existing login-item registration.

The saved pointer speed, sharing, automatic-switch and both DDC verification
preferences were compared before and after installation and remained unchanged.
No Windows installation, keyboard mapping, pairing reset, login-registration
mutation or user clipboard-content diagnostic was performed. The application
is installed and connected; the user's exact physical repeated-copy sequence
has not been observed to succeed by this validation.

## Primary API contracts

- [Apple NSPasteboard.string(forType:)](https://developer.apple.com/documentation/appkit/nspasteboard/string(fortype:)) calls `data(forType:)`.
- [Apple NSPasteboard.data(forType:)](https://developer.apple.com/documentation/appkit/nspasteboard/data(fortype:)) documents slow-owner IPC timeouts and communication exceptions.
- Swift task cancellation cannot interrupt an already-running synchronous native call; process isolation supplies the cancellation boundary here.

## Follow-up — 2026-11-18: Simulator clipboard synchronization

After v0.5.5 installation, the user reported that newly copied content still
failed to paste or was replaced by previously copied content. The earlier
main-loop blocking fix did not establish that this reported workflow was fixed.
The named-pasteboard tests above isolate reader behavior; they do not exercise
other applications synchronizing the Mac general pasteboard.

Live diagnosis found the general pasteboard advertising a text type while a
text read returned nil and its change count advanced during that read. The
installed v0.5.5 helper returned `unavailable` in about 35 ms. Access behavior
reported allowed. Counts continued advancing while idle, without content reads,
and the types included `com.apple.coredevice.dtpasteboardd.sync`. Four running
Simulator devices had corresponding `dtpasteboardd` synchronization processes.

A reversible comparison isolated the ownership churn to those synchronization
processes. These measurements sampled change counts only:

| Condition | Observed change count |
| --- | --- |
| Baseline, one second | 851577 → 851585 |
| Only the four Simulator synchronization processes paused | 11 samples remained at 851585 |
| The same processes resumed | 851589 → 851603 |
| Shared clipboard disabled for all four devices | 31 samples over three seconds remained at 854289 |

The configuration correction was to turn off **Edit → Use Shared Clipboard**
for each of the four running devices in Device Hub. Each device's menu was
reopened and verified unchecked. Afterward, the **same installed v0.5.5 helper**
returned a text result in **18.63 ms**. Clipboard payloads and personal device
names or identifiers are not recorded here. The canonical production source
contains no Mac pasteboard mutation or periodic clipboard-read loop; its helper
performs one read for an explicit Windows-entry request.

Three later reads against a newer general-pasteboard change count (`854290`)
also returned text, in **10.65 ms, 14.98 ms and 16.11 ms**. These were metadata-only
observations of the installed reader's result, not three distinct copy/paste
round trips. The diagnostic did not overwrite the general pasteboard or log its
payload.

This follow-up changed Device Hub configuration; it did not produce or install
a new CrossMouse build. The comparison confirms an external synchronization
cause for the observed Mac pasteboard instability and successful recovery of
the production reader after disabling that synchronization. It does not verify
the user's physical Mac → Windows paste → Mac → new copy sequence or a Windows
paste result. Those remain separate from a successful native clipboard read.

[Apple's Xcode 27 release notes](https://developer.apple.com/documentation/xcode-release-notes/xcode-27-release-notes.md)
describe Device Hub pasteboard timeout, synchronization-reliability and Universal
Clipboard synchronization fixes. They provide background context; they do not
identify which Apple issue caused this particular reproduction.
