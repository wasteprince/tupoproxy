# Coexisting HTTPS deployment

This layout lets tupoproxy share one public address without taking certificates
or ports away from existing projects:

1. HAProxy owns public TCP/443 and performs only SNI inspection/passthrough.
2. Credential SNI values go to tupoproxy on `127.0.0.1:8443` using PROXY v2.
3. Every other SNI goes to the existing HTTPS router on `127.0.0.1:9443`.
4. Invalid proxy authentication is masked to that same real HTTPS router.
5. The existing web server keeps public port 80 for ACME HTTP-01. DNS-01 also
   works and needs no inbound ACME port.

Replace every `example.com` value, create matching DNS A/AAAA records pointing
at the proxy host, and issue one SAN/wildcard certificate covering every
credential SNI. Validate the web path before publishing proxy links:

```sh
curl --resolve chrome.proxy.example.com:443:SERVER_IP https://chrome.proxy.example.com/
openssl s_client -connect SERVER_IP:443 -servername chrome.proxy.example.com </dev/null
```

The value distributed to Telegram remains the standard compatible format:
`ee + 16-byte-secret + hex(SNI)`. tupoproxy selects the server-side profile by
that SNI; adding private bytes after it would corrupt the domain and is not used.

## VPN coexistence

tupoproxy uses ordinary TCP and works through VPNs that route Telegram TCP
connections into the tunnel. Public TCP/443 is the most portable choice. No
server can override a phone VPN's kill switch, per-app exclusion, private-DNS
policy, or a tunnel that blocks the proxy address. If it fails only while the
VPN is enabled, allow Telegram in the VPN, disable its proxy exclusion, or add
the proxy address to the VPN route set.

Do not force a tiny MSS behind HAProxy: it would apply to the loopback leg, not
the client-facing TCP handshake. TCP stream reassembly also makes segmentation
an unreliable primary defense. The adaptive TLS-record profiles remain active
and tolerate the smaller effective MTU commonly introduced by VPN tunnels.
