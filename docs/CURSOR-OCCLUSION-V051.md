# Windows v0.5.1 — live pointer stacking

## What was observed

On 2026-10-11 the user reported that the pointer became hidden again after
initially working. A read-only inspection of the Mac control window confirmed
the authenticated peer was **Windows 0.5.0, login service, Default desktop**.
It was idle by the time of inspection. This is not a recording of the exact
invisible-pointer moment on the user's PC.

## Reproduced defect, with unchanged v0.5.0 rendering

Test-only commit `684ed1f` starts the normal production presenter, paints its
pointer, and then shows an opaque topmost popup above that same live surface.
The pointer remains active throughout; the test never hides/shows it to take
the next sample. Run `38104510709` reported:

```
reported=True, pixels=0, state=surface:Default
A later topmost popup covered the remote pointer while presentation still reported success.
```

The previous Chrome fixture called hide/show before every pixel sample. That
re-show could itself promote the pointer window, hiding the stacking defect.
The new controlled popup test proves this defect in our rendering contract;
it does not identify every possible cause of cursor invisibility on a physical PC.

## Change

`TopMost=true` selects a z-order group, not a permanent position above all
future windows. `UpdateLayeredWindow` succeeding is not proof that another
topmost window does not cover the result. Each refresh now checks the bounded
z-order/geometry above its own cursor surface and, when necessary, repositions
only that surface with `HWND_TOPMOST`, `SWP_NOACTIVATE` and `SWP_NOOWNERZORDER`.
Stationary and moving pointers use the same existing render clock.

No native cursor scheme, color rasterizer, mouse speed, F8, DDC, pairing key,
network profile, UAC policy or Mac application is changed. No user screenshots,
window titles or keyboard content are collected. The peer diagnostic includes
`stack-repairs:N` so the maintenance action is visible without collecting content.

Window rectangles alone do not prove pixel occlusion: another window can be
transparent or belong to a protected OS band. A geometry suspicion is therefore
not treated as a reason to disconnect input. We use supported ordering APIs for
our own window, not private z-band APIs or permission bypasses. Actual API
failures remain failures; no claim is made to display above every system UI band.

## Regression scope

The fixed test checks visible pixels after a later popup appears, 12 subsequent
raises with alternating stationary/moving input, no foreground activation,
click-through to the underlying button, popup dismissal and input-release hiding.
The test runs only in CI and restores its cursor and owned windows afterward.
Existing Chrome/folder picker, timing, native-X, desktop transition and service
upgrade/rollback tests remain enabled. Physical user-PC verification is separate.

Windows becomes v0.5.1. Mac remains v0.5.0 and understands the existing protocol.
The installer health check expects v0.5.1 and reuses the existing service/key.

## Official contract

- [Window z-order and topmost groups](https://learn.microsoft.com/en-us/windows/win32/winmsg/window-features)
- [SetWindowPos and nonactivating reordering](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowpos)
