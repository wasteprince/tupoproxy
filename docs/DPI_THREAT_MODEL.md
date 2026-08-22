# MTProxy and Russian DPI threat model

This document separates measured behavior, field reports, and server-side
controls. No static transport can guarantee operation against every future
block, IP allow-list, or total connectivity shutdown.

## Evidence summary

| Signal or action | Evidence | Server-side response |
| --- | --- | --- |
| Destination IP, subnet, and port blocks | General network capability; reported during MTProxy waves | Use TCP/443, multiple clean addresses, and operational rotation. No payload obfuscation can repair an IP-layer block. |
| TLS SNI parsing followed by RST/drop/throttling | Controlled TSPU measurements | Use a real controlled SNI whose DNS points to the proxy and expose a genuine HTTPS fallback. |
| Telegram FakeTLS ClientHello JA3/JA4 | Telegram client issue reports and current implementation source | Keep clients current. The stock proxy server cannot rewrite bytes already sent by the client. |
| Reassembly of a split ClientHello | Stateful DPI behavior and 2026 field reports | Do not treat MSS/fragmentation as the primary defense. Keep it optional only for older non-reassembling paths. |
| Fake server flight, record sizes, and fixed downstream shape | Active-probe and implementation analysis | Mirror a real origin ServerHello, vary downstream record sizes by credential SNI, and forward invalid authentication to the real origin. |
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
- Unknown or invalid traffic can be relayed to an actual TLS virtual host with
  a publicly valid certificate, which is stronger against active probing than
  a synthetic certificate-only response.
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

## Sources

- [Telegram MTProxy documentation](https://core.telegram.org/proxy)
- [Telegram MTProto transport specification](https://core.telegram.org/mtproto/mtproto-transports)
- [Censored Planet: TSPU — Russia's Decentralized Censorship System](https://censoredplanet.org/papers/tspu-imc22.pdf)
- [Censored Planet: Throttling Twitter](https://censoredplanet.org/assets/throttling-imc-paper.pdf)
- [Telegram Desktop issue #30733: static FakeTLS JA4](https://github.com/telegramdesktop/tdesktop/issues/30733)
- [Telegram Desktop issue #30734: segmented ClientHello failure](https://github.com/telegramdesktop/tdesktop/issues/30734)
- [Telegram Desktop FakeTLS implementation](https://github.com/telegramdesktop/tdesktop/blob/dev/Telegram/SourceFiles/mtproto/details/mtproto_tls_socket.cpp)
- [zapret documentation: TLS reassembly and segmentation limits](https://github.com/bol-van/zapret/blob/master/docs/readme.en.md)
- [Xray XHTTP transport documentation](https://xtls.github.io/en/config/transports/xhttp.html)
