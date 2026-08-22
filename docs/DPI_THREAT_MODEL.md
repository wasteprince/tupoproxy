# MTProxy and Russian DPI threat model

This document separates measured behavior, field reports, and server-side
controls. No static transport can guarantee operation against every future
block, IP allow-list, or total connectivity shutdown.

## Evidence summary

| Signal or action | Evidence | Server-side response |
| --- | --- | --- |
| Destination IP, subnet, and port blocks | General network capability; reported during MTProxy waves | Use TCP/443, multiple clean addresses, and operational rotation. No payload obfuscation can repair an IP-layer block. |
| TLS SNI parsing followed by RST/drop/throttling | Controlled TSPU measurements and OONI observations of resets/timeouts in 2026 | Separate the connection origin from the credential decoy SNI and expose a genuine HTTPS fallback for both roles. |
| Telegram FakeTLS ClientHello JA3/JA4 | A 2026 Telegram Desktop issue reports a static client fingerprint; its proposed fix is a closed client-side proof of concept, not an independently confirmed DPI rule | Keep clients current. The stock proxy server cannot rewrite bytes already sent by the client. |
| Reassembly of a split ClientHello | Stateful DPI behavior and 2026 field reports | Do not treat MSS/fragmentation as the primary defense. Keep it optional only for older non-reassembling paths. |
| Fake server flight, record sizes, and fixed downstream shape | Active-probe and implementation analysis | Mirror the real decoy ServerHello, vary downstream record sizes by credential SNI, and forward invalid authentication to the real decoy. |
| Repeated `(SNI, IP, port, fingerprint)` flow correlation | Field report; not yet reproduced by a public controlled study | Use several real credential SNIs and, where possible, more than one address. Avoid unrelated third-party SNI. |
| Length/timing statistics after the handshake | Generic encrypted-traffic classification literature and field reports | Padded-intermediate mode and bounded record-shape variation reduce static sizes, but cannot make a Telegram session semantically identical to web browsing. |
| Mobile allow-lists or all-TCP outage | Operator reports and protocol limits | A proxy cannot work without IP connectivity. A separate permitted VPN/tunnel or another network is required. |

## Design implemented in tupoproxy

- Standard `ee` credentials remain wire-compatible: the embedded SNI selects a
  `chrome`, `firefox`, `compat`, or `legacy` server profile.
- The selected profile controls the cover-origin probe and a connection-seeded,
  phased TLS record-size schedule. It does not claim to alter client JA4.
- Persisted cover profiles carry their probe-profile identity. A configuration
  change invalidates incompatible cached data before readiness checks.
- The automated deployment uses two names: an owned origin in the Telegram
  `server` parameter and a separately hosted HTTPS decoy in the credential
  SNI. Unknown or invalid decoy traffic is relayed to the decoy's actual TLS
  endpoint with its publicly valid certificate. The public proxy port and the
  decoy HTTPS port are independently configurable and verified.
- The automated deployment negotiates HTTP/2 on the real fallback, serves a
  per-installation origin cover page with normal static-file cache semantics,
  and verifies both public scanner-visible routes after startup. This removes
  the former shared `Welcome` response and ALPN mismatch between authenticated
  and fallback paths.
- TLS response framing varies independently of MTProto encryption. Cryptographic
  primitives are not replaced with experimental algorithms.
- The HAProxy deployment keeps normal sites and ACME independent while
  preserving client addresses through a trusted loopback-only PROXY v2 link.

## Why this is not XHTTP

XHTTP is an HTTP-aware bidirectional transport with cooperating client and
server implementations. Official Telegram clients speak MTProxy FakeTLS, so a
server-only fork cannot introduce XHTTP request semantics without breaking the
client. tupoproxy borrows only safe traffic-shape ideas. A local Xray client may
be used as an optional SOCKS upstream to put the server-to-Telegram leg inside
XHTTP/Reality, but it does not change the phone-to-proxy leg.

## ClientHello boundary

The first ClientHello crosses the censored network before tupoproxy receives
it. A server, reverse proxy, MSS setting, or packet scheduler cannot alter the
copy that a passive inline DPI has already observed. If an ISP blocks that
first flight by a stock Telegram fingerprint, eliminating the signal requires
a client update or a tunnel that begins before the monitored link. Server-side
record shaping still reduces response and active-probe signatures, but it must
not be presented as a fix for a client-side block.

## Sources

- [Telegram MTProxy documentation](https://core.telegram.org/proxy)
- [Telegram MTProto transport specification](https://core.telegram.org/mtproto/mtproto-transports)
- [Censored Planet: TSPU — Russia's Decentralized Censorship System](https://censoredplanet.org/papers/tspu-imc22.pdf)
- [Censored Planet: Throttling Twitter](https://censoredplanet.org/assets/throttling-imc-paper.pdf)
- [OONI: Russia blocked Telegram (March 2026)](https://explorer.ooni.org/findings/2026-russia-blocked-telegram)
- [Telegram Desktop issue #30788: reported static FakeTLS JA4 blocking](https://github.com/telegramdesktop/tdesktop/issues/30788)
- [Telegram Desktop PR #30738: closed client-side fingerprint proof of concept](https://github.com/telegramdesktop/tdesktop/pull/30738)
- [Telegram Desktop issue #30733: static FakeTLS JA4](https://github.com/telegramdesktop/tdesktop/issues/30733)
- [Telegram Desktop issue #30734: segmented ClientHello failure](https://github.com/telegramdesktop/tdesktop/issues/30734)
- [Telegram Desktop FakeTLS implementation](https://github.com/telegramdesktop/tdesktop/blob/dev/Telegram/SourceFiles/mtproto/details/mtproto_tls_socket.cpp)
- [zapret documentation: TLS reassembly and segmentation limits](https://github.com/bol-van/zapret/blob/master/docs/readme.en.md)
- [Xray XHTTP transport documentation](https://xtls.github.io/en/config/transports/xhttp.html)
