# Mac v0.5.3 — authenticated recovery after a changed IPv4 address

## Why the existing app could not recover

The user showed Windows listening at 192.168.219.108 while Mac still had the
old 192.168.219.104 in its host file. The old connection object retried its
immutable host forever. Manually replacing that file restored communication,
but it did not handle the next DHCP address change.

## Change and boundaries

Only Mac changes. Windows v0.5.1/v0.5.2 already speak the required existing
pairing and encrypted ping/pong protocol. No new listening port, Windows
service install, firewall exception, router login or mDNS service is required.

The saved address is attempted first, with the existing seven-second handshake
deadline. On failure the client enumerates the actual connected Wi-Fi/Ethernet
IPv4 interface/netmask. Discovery is restricted to ONE directly attached
RFC1918 subnet containing that previous address, with a real /24 through /30
mask. It excludes self, network, broadcast and known gateway addresses. Wider
subnets, another LAN prefix, public, IPv6, loopback and point-to-point/VPN
interfaces are not automatically searched. This deliberately does not promise
cross-router/VPN discovery; a different network needs explicit configuration.

At most four attempts run concurrently, solely on the configured CrossMouse
TCP port. Candidate attempts have a two-second deadline; a sweep has at most
254 candidates. Nearby addresses are tried first. A failed sweep is followed
by a minimum 30-second discovery cooldown, while the saved address continues
to be retried. Discovery stops immediately on success or explicit Stop. It
does not run while an authenticated connection is healthy. Offline/powered-off
PCs or blocked services cannot be made reachable by discovery.

Every candidate gets a fresh nonce. A TCP connection or the CMS1 magic is not
proof: the original pairing HMAC challenge AND a fresh AES-GCM ping/pong must
pass before adoption. No input or clipboard is sent during discovery. The
winning authenticated socket is reused, with its encryption counters preserved;
there is no second connection competing for Windows' single receiver slot.
Remaining candidate sockets are cancelled and stale completions are ignored.

The host hint is saved atomically only after authentication. Runtime recovery
can continue if saving fails, but the UI reports the failure; concurrent manual
host-file edits are preserved. A fresh app launch uses the last verified saved
address. The existing pairing file is not rewritten or reset.

Socket/handshake/discovery state uses one serial queue and lifetime tokens.
Unresponsive authenticated connections are released after a bounded silence
period instead of remaining TCP-connected forever. The app reports connecting,
automatic search, waiting or the authenticated current address. F8, DDC,
pointer raster/stacking, speed scaling, handoff and clipboard policy are not
modified. The transport moved to CrossMouseCore so its real NWConnection
behavior, not only a mocked selection state, can be tested.

## Automated validation

Local full Swift suite: 60 tests passed. The 9 new recovery tests also passed
as a separate repeat. They use only ephemeral loopback listeners and synthetic
keys; no real host/key/clipboard file, user input or LAN scan is used by tests.

Coverage includes actual encrypted continuation after the establishment timer
expires; direct success without discovery; wrong-key, silent and no-pong peers;
fragmented hello responses; stale-host fallback; cancellation during a delayed
handshake; Stop/Start with old callbacks; bounded retry cooldown; socket-drop
reconnection; candidate scope/exclusions; and successive saved-address changes
with preservation of concurrent manual edits.

These fixtures do not by themselves demonstrate a real DHCP lease renewal on
the user's Windows PC. Live installation and a stale-hint recovery check are
recorded separately after they are performed.

## Live Mac validation — 2026-10-17

Runtime commit: `d64a6c68c75118e142cb8791f3eb5c88b378a4e3`.
Mac v0.5.3 was signed with the same existing Apple Development identity and
installed at the canonical app path after backing up v0.5.2 and its preferences.
The Windows installation was not touched and still reports v0.5.1 service mode.

The saved hint was deliberately set back to the obsolete .104 address before
launching v0.5.3. Without a manually supplied new address, the installed app
found the existing paired .108 Windows receiver, authenticated its encrypted
response, saved .108 and displayed the automatic-recovery status. The complete
stale-hint recovery check took 8.51 seconds on this local network. This tests
real discovery with the user's existing receiver, not an actual DHCP renewal
or a guaranteed recovery time for every future network condition.

The app was then restarted again with the newly saved .108 hint. The existing
Windows service authenticated directly; the observed restart check completed
in 0.50 seconds. The final Mac window reports `192.168.219.108` and an authenticated
Windows v0.5.1 service. Speed 37%, automatic input switching, text-sharing
preference and registered login startup remained unchanged. The test did not
synthesize user input, inspect clipboard content, change the monitor input,
reset pairing, modify Windows/firewall settings or configure the router.

CI run `38991844744` passed the Mac job (tests, build and startup classification).
Its first Windows job failed in the unchanged Chrome test helper:
`Cdp.EvaluateAsync` / `ElementPoint`, `KeyNotFoundException` while reading a CDP
JSON property. The rest of that job's executed tests, including service and
clipboard checks, passed. That Windows failure is recorded rather than calling
the initial complete workflow green; Windows source/installer are unchanged by
this Mac networking change. One same-source retry also failed the Chrome test
step; its other executed steps and the Mac job passed. No Windows test was
disabled, relaxed or modified to hide this result. The full workflow is NOT
reported as green. The Mac change is supported by its passing suite/build and
the real stale-hint discovery/restart observations above.

API references:
- https://developer.apple.com/documentation/network/nwconnection
- https://developer.apple.com/documentation/network/nwparameters/requiredinterface
- https://developer.apple.com/documentation/network/nwpathmonitor
- https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy
