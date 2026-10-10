# Windows v0.4.4 pointer cadence validation

Code commit: `eae18102f0cc3c173c85388f31fd450a7a19bb78`.
Windows CI run: `38064090346`, job `114248101059`, 2026-10-10 15:34 UTC.

The same diagnostic compared the previous `System.Windows.Forms.Timer` set to
8 ms (including the prior receiver's `timeBeginPeriod` request) against the
new production waitable clock feeding the real pointer presenter. The legacy
side measures its timer callbacks, not a replay of the user's installed app.
The new presenter was forced into its missing-native-cursor display path.
No clicks, display input changes, or real pairing keys were used by this test.

| Path | Observed samples | Mean interval | p95 interval | Maximum interval |
|---|---:|---:|---:|---:|
| Legacy Forms timer, configured 8 ms | 128 | 15.62 ms | 21.78 ms | 22.00 ms |
| Shared high-resolution clock and pointer surface | 245 | 8.17 ms | 8.59 ms | 8.69 ms |

Each sampling window was approximately two seconds. These are Windows CI
observations, **not the user's PC refresh rate or proof that all reported
network/mouse stutter is gone**. The new native timer requested high resolution
successfully in this run; an ordinary timer fallback remains for unsupported
Windows versions and is identified by the diagnostic.

The busy-presentation regression accepted exactly one queued UI callback from
1,000 refresh requests. The input/render caller did not wait for the blocked
painting thread. Input-release hiding and cancellation of a wait also passed.
Existing real native-X, UI-independent receiver, hidden login startup, stationary
entry, and correlated handoff regressions all passed in the same Windows job.
Both macOS and Windows jobs completed successfully.

Scope: Windows rendering clock and optional cursor presentation only. The Mac
source, physical-motion speed scaling, F8/media return, HDMI-retaining crossings,
handoff wire fields, movement smoothing formula, pairing and login settings are
unchanged. Mac v0.4.3 remains compatible; only the Windows GUI needs replacement.
The user's running Mac application was not restarted or replaced for this work.
