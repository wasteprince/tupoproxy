# MTProxy and Russian DPI threat model

This document separates measured censorship capabilities, public field reports,
and controls that a server-side MTProxy implementation can actually provide.
No static transport can guarantee operation against every future rule, an IP
allow-list, address blocking, or a complete connectivity shutdown.

## Evidence summary

| Signal or action | Evidence level | tupoproxy response and limit |
| --- | --- | --- |
| Destination IP, subnet, or port block | General network capability and observed Telegram blocking | Publish on TCP/443 and keep operational address rotation available. Payload obfuscation cannot repair an IP-layer block. |
| SNI inspection, reset, drop, or throttling | TSPU measurements show stateful SNI, IP, and QUIC triggers; OONI reports resets and timeouts during the 2026 Telegram block | Use a plausible dedicated SNI and raw L4 routing on the shared HTTPS port. This cannot hide the SNI itself. |
| Static Telegram FakeTLS ClientHello JA3/JA4 | Public Telegram Desktop reports from May and June 2026; these are field reports, not an independently reproduced TSPU rule | Keep Telegram clients current. A server cannot modify the ClientHello after the client sent it. |
| Reassembly of a segmented ClientHello | TSPU is stateful at IP and TCP layers; client field reports describe segmentation failures | Do not treat MSS or packet splitting as the primary defense. Stateful DPI can reassemble the first flight. |
| Fixed FakeTLS server flight and record sizes | Protocol and implementation analysis | Authenticate the complete first server flight, select client-offered TLS 1.3 parameters, and apply bounded record-profile variation after authentication. |
| Active probes with an invalid credential | Generic proxy-discovery method | Close the dedicated FakeTLS branch without a certificate, HTTP response, or relay to another origin. This matches the selected HMAC-only deployment policy but is not a genuine website fallback. |
| Long-flow length and timing statistics | Generic encrypted-traffic classification literature | Padded intermediate mode and bounded record shaping reduce static sizes. They cannot make an MTProto session semantically identical to browsing. |
| Mobile allow-list, VPN routing failure, or all-TCP outage | Operator policy and protocol limits | The proxy works through a VPN when that VPN permits the endpoint. It cannot create reachability when the VPN or access network blocks the server IP. |

## Installed architecture

- The Telegram link contains a Base64URL credential whose decoded form is
  `0xee | 16-byte secret | FakeTLS SNI`.
- The public `server` value is the existing origin domain, which must resolve
  directly to the VPS; the public port is always TCP/443.
- nginx `stream_ssl_preread` or Caddy layer4 owns TCP/443. It reads only SNI and
  passes the selected FakeTLS branch as raw TCP plus PROXY protocol v2 to the
  private tupoproxy listener on TCP/18443.
- Existing HTTPS names continue through the reverse proxy's original route.
  The FakeTLS branch does not terminate TLS at nginx or Caddy, so its original
  authenticated ClientHello reaches tupoproxy byte-for-byte.
- A valid timestamped HMAC receives the normal FakeTLS ServerHello flight. An
  invalid HMAC, replay, or unsupported handshake closes without certificate or
  fallback (`mask = false`, `unknown_sni_action = "drop"`).
- `chrome`, `firefox`, `compat`, and `legacy` select server-side response and
  record schedules. They do not change the client-side JA3/JA4 fingerprint.
- The installer verifies the deployed route with a real authenticated
  ClientHello and validates the HMAC over the returned server flight.

## Why the reverse proxy does not conflict with FakeTLS

HTTP reverse proxying would terminate TLS and generate a different upstream
connection, invalidating the HMAC over the original ClientHello. The deployed
route is L4 pass-through instead: edge reads enough bytes to select the SNI,
then forwards those same bytes. PROXY v2 is added only on the private hop and is
consumed before tupoproxy parses the ClientHello.

This also explains why a separate SNI can share TCP/443 with many ordinary
sites. The reverse proxy selects the branch by hostname before any endpoint
terminates TLS.

## Why this is not XHTTP

XHTTP is an HTTP-aware transport that requires cooperating client and server
implementations. Official Telegram clients speak MTProxy FakeTLS, so a
server-only fork cannot add XHTTP requests without breaking compatibility.
tupoproxy can vary TLS record boundaries and downstream write phases, but it
does not claim that the resulting flow is semantically identical to XHTTP.

## ClientHello boundary

The ClientHello crosses the monitored access network before the server or its
reverse proxy receives it. ServerHello selection, response fragmentation, MSS,
and downstream scheduling cannot erase a fingerprint already present in that
first client flight. If a network blocks that fingerprint, the complete remedy
requires a Telegram client update or a permitted tunnel that starts before the
monitored link.

## Sources

- [Telegram MTProxy documentation](https://core.telegram.org/proxy)
- [Telegram MTProto transport specification](https://core.telegram.org/mtproto/mtproto-transports)
- [Telegram deep-link format](https://core.telegram.org/api/links)
- [Censored Planet: TSPU — Russia's Decentralized Censorship System](https://censoredplanet.org/papers/tspu-imc22.pdf)
- [OONI: Russia blocked Telegram (March 2026)](https://explorer.ooni.org/findings/2026-russia-blocked-telegram)
- [Telegram Desktop issue #30733: reported static FakeTLS JA4](https://github.com/telegramdesktop/tdesktop/issues/30733)
- [Telegram Desktop issue #30734: reported platform-dependent TSPU failure](https://github.com/telegramdesktop/tdesktop/issues/30734)
- [Telegram Desktop issue #30788: duplicate MTProxy field report](https://github.com/telegramdesktop/tdesktop/issues/30788)
- [Telegram Desktop PR #30738: client-side fingerprint proposal](https://github.com/telegramdesktop/tdesktop/pull/30738)
- [Telegram Desktop FakeTLS implementation](https://github.com/telegramdesktop/tdesktop/blob/dev/Telegram/SourceFiles/mtproto/details/mtproto_tls_socket.cpp)
- [Xray XHTTP transport documentation](https://xtls.github.io/en/config/transports/xhttp.html)
