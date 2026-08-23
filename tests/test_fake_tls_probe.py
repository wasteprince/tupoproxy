"""Regression tests for the authenticated FakeTLS readiness probe."""

from __future__ import annotations

import hashlib
import hmac
import importlib.util
from pathlib import Path
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "fake-tls-probe.py"
SPEC = importlib.util.spec_from_file_location("fake_tls_probe", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
PROBE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROBE)


def server_flight(secret: bytes, client_digest: bytes) -> bytes:
    session_id = bytes(range(32))
    body = (
        b"\x02\x00\x00\x00"
        + b"\x03\x03"
        + bytes(32)
        + bytes([len(session_id)])
        + session_id
        + b"\x13\x01\x00\x00\x06"
        + b"\x00\x2b\x00\x02\x03\x04"
    )
    body = body[:1] + len(body[4:]).to_bytes(3, "big") + body[4:]
    server_hello = b"\x16\x03\x03" + len(body).to_bytes(2, "big") + body
    change_cipher_spec = b"\x14\x03\x03\x00\x01\x01"
    application_data = b"\x17\x03\x03\x00\x40" + bytes(range(64))
    response = bytearray(server_hello + change_cipher_spec + application_data)
    digest = hmac.new(secret, client_digest + response, hashlib.sha256).digest()
    response[PROBE.DIGEST_POSITION : PROBE.DIGEST_POSITION + PROBE.DIGEST_LENGTH] = digest
    return bytes(response)


class FakeTlsProbeTests(unittest.TestCase):
    def test_client_hello_contains_a_valid_timestamped_hmac(self) -> None:
        secret = bytes.fromhex("00112233445566778899aabbccddeeff")
        timestamp = 1_700_000_000

        hello = PROBE.build_client_hello("proxy.example.com", secret, timestamp)

        digest = hello[PROBE.DIGEST_POSITION : PROBE.DIGEST_POSITION + PROBE.DIGEST_LENGTH]
        canonical = bytearray(hello)
        canonical[PROBE.DIGEST_POSITION : PROBE.DIGEST_POSITION + PROBE.DIGEST_LENGTH] = bytes(32)
        computed = hmac.new(secret, canonical, hashlib.sha256).digest()
        self.assertEqual(digest[:28], computed[:28])
        decoded_timestamp = bytes(digest[index] ^ computed[index] for index in range(28, 32))
        self.assertEqual(int.from_bytes(decoded_timestamp, "little"), timestamp)
        self.assertIn(b"proxy.example.com", hello)

    def test_server_flight_hmac_and_record_sequence_are_accepted(self) -> None:
        secret = bytes.fromhex("00112233445566778899aabbccddeeff")
        client_digest = bytes(range(32))
        response = server_flight(secret, client_digest)

        record_types = PROBE.validate_server_flight(response, client_digest, secret)

        self.assertEqual(
            record_types,
            [
                PROBE.TLS_HANDSHAKE,
                PROBE.TLS_CHANGE_CIPHER_SPEC,
                PROBE.TLS_APPLICATION_DATA,
            ],
        )

    def test_server_flight_with_wrong_hmac_is_rejected(self) -> None:
        secret = bytes.fromhex("00112233445566778899aabbccddeeff")
        client_digest = bytes(range(32))
        response = bytearray(server_flight(secret, client_digest))
        response[PROBE.DIGEST_POSITION] ^= 1

        with self.assertRaisesRegex(PROBE.ProbeError, "server HMAC"):
            PROBE.validate_server_flight(bytes(response), client_digest, secret)


if __name__ == "__main__":
    unittest.main()
