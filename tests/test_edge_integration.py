"""Regression tests for the Layer-4 reverse-proxy integration helper."""

from __future__ import annotations

import importlib.util
from pathlib import Path
import subprocess
import unittest
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "edge-integration.py"
SPEC = importlib.util.spec_from_file_location("edge_integration", MODULE_PATH)
assert SPEC is not None and SPEC.loader is not None
EDGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(EDGE)


class CaddyPatchTests(unittest.TestCase):
    def test_existing_global_block_preserves_raw_faketls_route(self) -> None:
        source = """{
    email admin@example.com
}

example.com {
    respond "existing site"
}
"""

        patched = EDGE.patch_caddy(source, "decoy.example.org", "127.0.0.1:18443", 443)

        self.assertIn("servers :443", patched)
        self.assertIn("@tupoproxy tls sni decoy.example.org", patched)
        self.assertIn("upstream tcp/127.0.0.1:18443", patched)
        self.assertIn("Preserve FakeTLS bytes", patched)
        self.assertIn('respond "existing site"', patched)
        self.assertLess(patched.index("layer4 {"), patched.index("        tls\n"))

    def test_missing_global_block_gets_one_managed_block(self) -> None:
        source = "example.com {\n    respond \"ok\"\n}\n"

        patched = EDGE.patch_caddy(source, "decoy.example.org", "127.0.0.1:18443", 8443)
        patched_again = EDGE.patch_caddy(
            patched,
            "decoy.example.org",
            "127.0.0.1:18443",
            8443,
        )

        self.assertTrue(patched.startswith("# BEGIN TUPOPROXY EDGE\n{\n"))
        self.assertIn("servers :8443", patched)
        self.assertEqual(patched_again.count(EDGE.BEGIN_MARKER), 1)

    def test_existing_server_listener_wrappers_are_extended_in_place(self) -> None:
        source = """{
    servers :443 {
        protocols h1 h2
        listener_wrappers {
            proxy_protocol
            tls
        }
    }
}

example.com {
    respond "ok"
}
"""

        patched = EDGE.patch_caddy(source, "decoy.example.org", "127.0.0.1:18443", 443)

        self.assertEqual(patched.count("servers :443"), 1)
        self.assertEqual(patched.count("listener_wrappers"), 1)
        self.assertIn("proxy_protocol", patched)
        self.assertLess(patched.index("            proxy_protocol\n"), patched.index("layer4 {"))
        self.assertLess(patched.index("layer4 {"), patched.index("            tls\n"))


class NginxPatchTests(unittest.TestCase):
    def test_https_listeners_are_relocated_and_restorable(self) -> None:
        source = """server {
    listen 443 ssl http2;
    listen [::]:443 ssl;
    server_name example.com;
}
"""

        patched, changed, has_ipv4, has_ipv6 = EDGE.patch_nginx_listeners(
            source,
            443,
            24443,
        )

        self.assertEqual(changed, 2)
        self.assertTrue(has_ipv4)
        self.assertTrue(has_ipv6)
        self.assertIn("listen 127.0.0.1:24443 ssl http2 proxy_protocol;", patched)
        self.assertIn("listen [::1]:24443 ssl proxy_protocol;", patched)
        self.assertEqual(EDGE.restore_nginx_listeners(patched), source)

    def test_stream_route_uses_preread_without_tls_termination(self) -> None:
        block = EDGE.nginx_stream_block(
            "decoy.example.org",
            "127.0.0.1:18443",
            "127.0.0.1:24443",
            True,
            False,
            443,
        )

        self.assertIn("ssl_preread on;", block)
        self.assertIn("proxy_protocol on;", block)
        self.assertIn("decoy.example.org 127.0.0.1:18443;", block)
        self.assertIn("default 127.0.0.1:24443;", block)
        self.assertIn("listen 443;", block)
        self.assertNotIn("listen [::]:443;", block)
        self.assertNotIn("ssl_certificate", block)


class ManagedCaddyTests(unittest.TestCase):
    def test_generated_site_keeps_tls_termination_after_layer4(self) -> None:
        config = EDGE.managed_caddyfile(
            "proxy.example.com",
            "decoy.example.org",
            "172.17.0.1:18443",
        )

        self.assertIn("servers :443", config)
        self.assertIn("upstream tcp/172.17.0.1:18443", config)
        self.assertIn("proxy_protocol v2", config)
        self.assertIn("proxy.example.com {", config)
        self.assertLess(config.index("layer4 {"), config.index("        tls\n"))

    def test_preserved_managed_caddy_keeps_site_without_proxy_route(self) -> None:
        config = EDGE.preserved_managed_caddyfile("proxy.example.com")

        self.assertIn("proxy.example.com {", config)
        self.assertIn("Welcome", config)
        self.assertNotIn("layer4", config)
        self.assertNotIn("tupoproxy", config)

    def test_target_record_includes_the_container_listener_port(self) -> None:
        record = EDGE.target_record(
            {
                "kind": "docker-caddy",
                "target": "web",
                "backend_ip": "172.17.0.1",
                "trusted_cidr": "172.17.0.0/16",
                "edge_port": 8443,
            }
        )

        self.assertEqual(
            record,
            "docker-caddy\tweb\t172.17.0.1\t172.17.0.0/16\t8443",
        )

    def test_docker_host_port_maps_to_the_container_listener(self) -> None:
        container = {
            "HostConfig": {"NetworkMode": "bridge"},
            "NetworkSettings": {
                "Ports": {
                    "8443/tcp": [{"HostIp": "0.0.0.0", "HostPort": "443"}],
                }
            },
        }

        self.assertEqual(EDGE.docker_mapped_port(container, 443), 8443)
        self.assertIsNone(EDGE.docker_mapped_port(container, 9443))

    def test_docker_host_config_mapping_is_used_as_a_fallback(self) -> None:
        container = {
            "HostConfig": {
                "NetworkMode": "bridge",
                "PortBindings": {
                    "8443/tcp": [{"HostIp": "0.0.0.0", "HostPort": "443"}],
                },
            },
            "NetworkSettings": {"Ports": {}},
        }

        self.assertEqual(EDGE.docker_mapped_port(container, 443), 8443)

    def test_standard_docker_caddy_is_reported_as_upgradeable(self) -> None:
        container = {
            "Id": "a" * 64,
            "Name": "/web-edge",
            "Config": {
                "Entrypoint": ["/usr/bin/caddy"],
                "Cmd": ["run", "--config", "/etc/caddy/Caddyfile"],
                "Labels": {},
            },
            "HostConfig": {
                "NetworkMode": "bridge",
                "PortBindings": {
                    "443/tcp": [{"HostIp": "0.0.0.0", "HostPort": "443"}],
                },
            },
            "NetworkSettings": {
                "Ports": {},
                "Networks": {
                    "edge": {"Gateway": "172.19.0.1", "IPPrefixLen": 16},
                },
            },
            "Mounts": [{"Destination": "/etc/caddy", "Type": "bind"}],
        }

        def command_result(_container_id: str, command: list[str]) -> subprocess.CompletedProcess[str]:
            if command == ["caddy", "list-modules"]:
                return subprocess.CompletedProcess(command, 0, "http\n", "")
            if command == ["sh", "-c", "command -v caddy"]:
                return subprocess.CompletedProcess(command, 0, "/usr/bin/caddy\n", "")
            if command[:2] == ["test", "-e"]:
                return subprocess.CompletedProcess(command, 1, "", "")
            return subprocess.CompletedProcess(command, 0, "", "")

        with (
            mock.patch.object(EDGE, "docker_containers", return_value=[container]),
            mock.patch.object(EDGE, "docker_command", side_effect=command_result),
        ):
            target = EDGE.docker_target(443)

        self.assertIsNotNone(target)
        assert target is not None
        self.assertEqual(target["kind"], "upgradeable-docker-caddy")
        self.assertEqual(target["target"], "web-edge")
        self.assertEqual(target["edge_port"], 443)
        self.assertEqual(target["backend_ip"], "172.19.0.1")
        self.assertEqual(target["caddy_executable"], "/usr/bin/caddy")

    def test_docker_caddy_upgrade_keeps_a_restorable_binary(self) -> None:
        target = {
            "kind": "upgradeable-docker-caddy",
            "target": "web-edge",
            "container_id": "a" * 64,
            "runtime_config": "/etc/caddy/Caddyfile",
            "caddy_executable": "/usr/bin/caddy",
        }

        def run_result(command: list[str], **_kwargs: object) -> subprocess.CompletedProcess[str]:
            return subprocess.CompletedProcess(command, 0, "", "")

        def command_result(_container_id: str, command: list[str]) -> subprocess.CompletedProcess[str]:
            return subprocess.CompletedProcess(command, 0, "layer4\n", "")

        with (
            mock.patch.object(EDGE, "run", side_effect=run_result) as run_command,
            mock.patch.object(EDGE, "docker_command", side_effect=command_result),
        ):
            upgraded = EDGE.upgrade_docker_caddy(target)

        self.assertEqual(upgraded["kind"], "docker-caddy")
        self.assertTrue(upgraded["caddy_binary_upgraded"])
        self.assertEqual(upgraded["caddy_binary_backup"], "/usr/bin/caddy.tmp")
        add_package_command = run_command.call_args_list[0].args[0]
        self.assertIn("add-package", add_package_command)
        self.assertIn("--keep-backup", add_package_command)
        self.assertIn(EDGE.CADDY_L4_PACKAGE, add_package_command)


if __name__ == "__main__":
    unittest.main()
