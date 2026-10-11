# v0.5.2 — Mac to Windows text clipboard

## User behavior

Enable **Mac → Windows 텍스트 클립보드 공유** in the Mac window. Copy text on
Mac, cross to Windows, and use Windows' ordinary Ctrl+V or Paste menu. This is
one-way plain-text transfer, including Korean, emoji, links, tabs and code.
Images, files, HTML/RTF formatting and Windows-to-Mac transfer are not included.
The maximum is 256 KiB of UTF-8; over-limit text is refused, never truncated.
Win32 line endings are normalized to CRLF. No keystrokes are synthesized to
paste or execute content: the destination application's Paste behavior is used.

There is no periodic clipboard read or cloud relay. A pasteboard read happens
only at an explicit Windows entry, after the paired receiver advertised
`text-chunks-1`. The setting is persisted on Mac and is off for fresh users until
enabled. The user requesting this feature may enable it on their installed Mac.
After an acknowledged successful transfer, unchanged Mac clipboard content is
not retransmitted on another crossing, preserving subsequent Windows copies.
A failed transfer remains retryable on the next entry. Copying the same text
again on Mac also creates a fresh transfer. Turning sharing off stops future
transfers; it does not erase content already in the Windows clipboard.

## Transport and clipboard boundary

The existing AES-GCM authenticated TCP connection carries bounded chunks with
the current prepared handoff ID and a separate clipboard transaction ID. The
4096-byte encrypted-frame limit is unchanged. At most 256 KiB is assembled per
connection. Chunks contain padded base64url so neither JSON encoder expands
slashes/plus signs beyond that limit. The sender completion-paces chunks and
drops the unsent remainder on cancellation or reconnect; heartbeats can interleave.

Windows accepts clipboard data only for the prepared, not-yet-active input
handoff, on the Default input desktop. Login, lock, UAC and other input desktops
are not clipboard destinations. Clipboard sharing failure does not grant input,
change screen selection or break keyboard/mouse sharing. The original entry
continues after an explicit result or the bounded clipboard timeout.

After complete ordered assembly and strict UTF-8 validation, the interactive
receiver/agent writes CF_UNICODETEXT using a short-lived message-only owner HWND.
The session-zero boot broker never opens the clipboard. Clipboard contention is
retried for at most 250 ms, not on the input-render thread. Authorization and the
input desktop are rechecked before mutation. A changed Windows clipboard sequence
number prevents replacing a new local copy made during transfer. Incomplete,
duplicate, stale, out-of-order, oversized and NUL-containing content is rejected.

## Privacy

Clipboard payloads are not passed to operational logs or temporary files. The
receiver never reads or sends Windows clipboard content. Recognized concealed,
transient, auto-generated, remote-clipboard and file-copy markers are excluded
on Mac. These are advisory markers; not every password application supplies them,
so this is not a universal password detector. Ordinary unmarked copied text is
shared when enabled. Content is accessible to other applications through the
ordinary Windows clipboard after transfer.

The write includes `ExcludeClipboardContentFromMonitorProcessing`, opting out of
Windows clipboard history and cloud synchronization for this item. This does not
prevent unrelated third-party clipboard managers from reading clipboard content.
No password, UAC, firewall, pairing or service-permission policy is loosened for
this feature. Existing service update/rollback and login paths are reused.

## Verification boundaries

Mac tests use uniquely named pasteboards, not the user's general pasteboard.
Windows clipboard tests are CI-only and use synthetic text. Tests cover Unicode,
long code, unchanged-copy preservation, marked/unsupported types, wire-size bounds,
strict chunk assembly, local-copy conflict, busy clipboard retry and real encrypted
Ctrl+V delivery into an owned native text box. Service integration tests transfer
text from the SYSTEM interactive agent to another process on Default and reject
clipboard writes after switching to a separate test desktop.

These tests do not read, print or paste the user's real clipboard, and do not
establish that the user has installed the new Windows version. F8, DDC, pointer
speed, cursor raster/stacking, motion rendering and existing wire crypto are not
replaced by this feature.

Official contracts:
- [Apple NSPasteboard.changeCount](https://developer.apple.com/documentation/appkit/nspasteboard/changecount).
- [Microsoft SetClipboardData](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setclipboarddata): owner HWND and GMEM_MOVEABLE ownership.
- [Microsoft Clipboard Formats](https://learn.microsoft.com/en-us/windows/win32/dataxchg/clipboard-formats): ExcludeClipboardContentFromMonitorProcessing.

## Recorded validation and local application

Runtime commit: `f442d67a76d3c9bee71a1e09b1bc81389b8339a3`.
CI run `38115457090`: Windows and macOS jobs succeeded. All 51 Swift tests
passed locally. The Windows job logged successful encrypted Unicode/long-code
transfer and real Ctrl+V, newer-local-copy preservation, busy clipboard retry,
history exclusion and chunk validation. The installed SYSTEM service also
published a Default clipboard item readable by another process and rejected a
non-Default write. Existing cursor visibility/stacking, native X, idle entry,
service lifecycle and failed-upgrade rollback checks remained green.

The Mac v0.5.2 app was signed with the existing development identity and applied
at the existing canonical path, after backing up the prior app and preferences.
The new text-sharing checkbox was enabled for this requesting user. The UI then
showed 37% pointer speed, the existing registered login item, working input
capture and a connected Windows v0.5.1 service. Therefore Windows still needs the
v0.5.2 update before this user's clipboard can transfer; no physical user-PC
paste success is claimed. No general clipboard content was inspected or printed
by the development tools.
