#!/usr/bin/env python3
"""Verify an authenticated Telegram FakeTLS endpoint without relaying traffic."""

from __future__ import annotations

import argparse
import hashlib
import hmac
import socket
import ssl
import time


DIGEST_POSITION = 11
DIGEST_LENGTH = 32
TLS_HANDSHAKE = 22
TLS_CHANGE_CIPHER_SPEC = 20
TLS_APPLICATION_DATA = 23


class ProbeError(RuntimeError):
    """Raised when an endpoint does not complete an authenticated FakeTLS flight."""


def build_client_hello(server_name: str, secret: bytes, timestamp: int | None = None) -> bytes:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE
    context.set_alpn_protocols(["h2", "http/1.1"])
    incoming = ssl.MemoryBIO()
    outgoing = ssl.MemoryBIO()
    connection = context.wrap_bio(
        incoming,
        outgoing,
        server_side=False,
        server_hostname=server_name,
    )
    try:
        connection.do_handshake()
    except ssl.SSLWantReadError:
        pass

    hello = bytearray(outgoing.read())
    if len(hello) < DIGEST_POSITION + DIGEST_LENGTH or hello[0] != TLS_HANDSHAKE:
        raise ProbeError("the local TLS library did not generate a usable ClientHello")
    record_length = int.from_bytes(hello[3:5], "big")
    if len(hello) != 5 + record_length:
        raise ProbeError("the local TLS library generated an unexpected initial flight")

    hello[DIGEST_POSITION : DIGEST_POSITION + DIGEST_LENGTH] = bytes(DIGEST_LENGTH)
    digest = bytearray(hmac.new(secret, hello, hashlib.sha256).digest())
    unix_time = int(time.time()) if timestamp is None else timestamp
    encoded_time = unix_time.to_bytes(4, "little", signed=False)
    for index, value in enumerate(encoded_time):
        digest[28 + index] ^= value
    hello[DIGEST_POSITION : DIGEST_POSITION + DIGEST_LENGTH] = digest
    return bytes(hello)


def read_exact(connection: socket.socket, length: int) -> bytes:
    chunks: list[bytes] = []
    remaining = length
    while remaining:
        chunk = connection.recv(remaining)
        if not chunk:
            raise ProbeError("the endpoint closed the connection during the FakeTLS response")
        chunks.append(chunk)
        remaining -= len(chunk)
    return b"".join(chunks)


def read_tls_record(connection: socket.socket) -> bytes:
    header = read_exact(connection, 5)
    length = int.from_bytes(header[3:5], "big")
    if length > 16_384:
        raise ProbeError("the endpoint returned an oversized TLS record")
    return header + read_exact(connection, length)


def validate_server_flight(response: bytes, client_digest: bytes, secret: bytes) -> list[int]:
    if len(client_digest) != DIGEST_LENGTH:
        raise ProbeError("invalid client digest length")
    if len(response) < DIGEST_POSITION + DIGEST_LENGTH:
        raise ProbeError("the FakeTLS response is too short")

    record_types: list[int] = []
    offset = 0
    while offset < len(response):
        if offset + 5 > len(response):
            raise ProbeError("the FakeTLS response contains a truncated record header")
        length = int.from_bytes(response[offset + 3 : offset + 5], "big")
        end = offset + 5 + length
        if end > len(response):
            raise ProbeError("the FakeTLS response contains a truncated record")
        record_types.append(response[offset])
        offset = end

    if record_types != [TLS_HANDSHAKE, TLS_CHANGE_CIPHER_SPEC, TLS_APPLICATION_DATA]:
        raise ProbeError(f"unexpected FakeTLS record sequence: {record_types}")

    stored_digest = response[DIGEST_POSITION : DIGEST_POSITION + DIGEST_LENGTH]
    canonical = bytearray(response)
    canonical[DIGEST_POSITION : DIGEST_POSITION + DIGEST_LENGTH] = bytes(DIGEST_LENGTH)
    expected_digest = hmac.new(secret, client_digest + canonical, hashlib.sha256).digest()
    if not hmac.compare_digest(stored_digest, expected_digest):
        raise ProbeError("the endpoint returned an invalid FakeTLS server HMAC")
    return record_types


def split_endpoint(value: str) -> tuple[str, int]:
    if value.startswith("["):
        closing = value.find("]")
        if closing < 0 or closing + 1 >= len(value) or value[closing + 1] != ":":
            raise argparse.ArgumentTypeError("IPv6 endpoints must use [address]:port")
        host = value[1:closing]
        port_text = value[closing + 2 :]
    else:
        if ":" not in value:
            raise argparse.ArgumentTypeError("endpoint must use host:port")
        host, port_text = value.rsplit(":", 1)
    try:
        port = int(port_text)
    except ValueError as error:
        raise argparse.ArgumentTypeError("endpoint port must be numeric") from error
    if not host or not 1 <= port <= 65_535:
        raise argparse.ArgumentTypeError("endpoint is out of range")
    return host, port


def probe(endpoint: tuple[str, int], server_name: str, secret: bytes, timeout: float) -> int:
    hello = build_client_hello(server_name, secret)
    client_digest = hello[DIGEST_POSITION : DIGEST_POSITION + DIGEST_LENGTH]
    with socket.create_connection(endpoint, timeout=timeout) as connection:
        connection.settimeout(timeout)
        connection.sendall(hello)
        response = b"".join(read_tls_record(connection) for _ in range(3))
    validate_server_flight(response, client_digest, secret)
    return len(response)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--connect", required=True, type=split_endpoint)
    result.add_argument("--sni", required=True)
    result.add_argument("--secret", required=True)
    result.add_argument("--timeout", type=float, default=8.0)
    return result


def main() -> int:
    args = parser().parse_args()
    try:
        secret = bytes.fromhex(args.secret)
    except ValueError as error:
        raise ProbeError("secret must be hexadecimal") from error
    if len(secret) != 16:
        raise ProbeError("secret must contain exactly 16 bytes")
    if not 0.5 <= args.timeout <= 60:
        raise ProbeError("timeout must be between 0.5 and 60 seconds")
    response_length = probe(args.connect, args.sni, secret, args.timeout)
    print(f"FakeTLS authentication succeeded; server flight: {response_length} bytes")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ProbeError) as error:
        raise SystemExit(f"FakeTLS probe failed: {error}") from error
