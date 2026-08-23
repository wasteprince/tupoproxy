#!/usr/bin/env python3
"""Integrate tupoproxy with an existing or managed Layer-4 TLS edge."""

from __future__ import annotations

import argparse
import base64
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from typing import Any


BEGIN_MARKER = "# BEGIN TUPOPROXY EDGE"
END_MARKER = "# END TUPOPROXY EDGE"
NGINX_ORIGINAL_MARKER = "TUPOPROXY_ORIGINAL="
DEFAULT_INTERNAL_HTTPS_PORT = 24443
MANAGED_CADDY_CONTAINER = "tupoproxy-caddy"
MANAGED_CADDY_IMAGE = "tupoproxy/caddy-l4:managed"
MANAGED_CADDY_LABEL = "io.tupoproxy.managed"
MANAGED_DIRECTORY_MARKER = ".tupoproxy-managed"
MANAGED_CADDY_VERSION = "2.11.4"
MANAGED_CADDY_L4_VERSION = "0.1.2"


class IntegrationError(RuntimeError):
    """Reports a safe, user-facing integration failure."""


def run(
    command: list[str],
    *,
    check: bool = True,
    capture: bool = True,
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        command,
        check=check,
        text=True,
        input=input_text,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
    )


def command_exists(command: str) -> bool:
    return shutil.which(command) is not None


def listener_details(port: int) -> str:
    if not command_exists("ss"):
        return ""
    result = run(
        ["ss", "-H", "-ltnp", f"sport = :{port}"],
        check=False,
    )
    return f"{result.stdout}\n{result.stderr}".lower()


def listener_host_process(details: str, name: str) -> tuple[str, list[str]] | None:
    root_stat = os.stat("/")
    process_ids = re.findall(rf'"{re.escape(name)}",pid=([0-9]+)', details)
    for process_id in process_ids:
        try:
            process_root = os.stat(f"/proc/{process_id}/root")
            if (process_root.st_dev, process_root.st_ino) != (root_stat.st_dev, root_stat.st_ino):
                continue
            executable = os.readlink(f"/proc/{process_id}/exe")
            command_line = Path(f"/proc/{process_id}/cmdline").read_bytes()
        except OSError:
            continue
        arguments = [
            value.decode("utf-8", errors="replace")
            for value in command_line.split(b"\0")
            if value
        ]
        return executable, arguments
    return None


def option_value(arguments: list[str], *options: str) -> str | None:
    for index, value in enumerate(arguments):
        for option in options:
            if value == option and index + 1 < len(arguments):
                return arguments[index + 1]
            if value.startswith(f"{option}="):
                return value.split("=", 1)[1]
    return None


def validate_path(path: str) -> str:
    if not re.fullmatch(r"/[A-Za-z0-9_./-]+", path):
        raise IntegrationError(f"unsafe configuration path: {path}")
    return path


def host_caddy_target(port: int) -> dict[str, Any] | None:
    details = listener_details(port)
    process = listener_host_process(details, "caddy")
    if not process:
        return None
    caddy, arguments = process
    modules = run([caddy, "list-modules"], check=False)
    if modules.returncode != 0 or not re.search(r"(?m)^layer4(?:\.|$)", modules.stdout):
        return None
    adapter = option_value(arguments, "--adapter") or "caddyfile"
    if adapter != "caddyfile":
        return None
    config = validate_path(option_value(arguments, "--config") or "/etc/caddy/Caddyfile")
    if not Path(config).is_file():
        return None
    return {
        "kind": "host-caddy",
        "target": "host",
        "runtime_config": config,
        "executable": caddy,
        "backend_ip": "127.0.0.1",
        "trusted_cidr": "127.0.0.1/32",
        "edge_port": port,
    }


def nginx_supports_preread(command: list[str]) -> bool:
    version = run(command + ["-V"], check=False)
    output = f"{version.stdout}\n{version.stderr}"
    return "--with-stream_ssl_preread_module" in output


def nginx_config_path(command: list[str], arguments: list[str]) -> str:
    explicit = option_value(arguments, "-c")
    if explicit:
        return validate_path(explicit)
    version = run(command + ["-V"], check=False)
    match = re.search(r"--conf-path=([^\s]+)", f"{version.stdout} {version.stderr}")
    return validate_path(match.group(1) if match else "/etc/nginx/nginx.conf")


def host_nginx_target(port: int) -> dict[str, Any] | None:
    details = listener_details(port)
    process = listener_host_process(details, "nginx")
    if not process:
        return None
    nginx, arguments = process
    if not nginx_supports_preread([nginx]):
        return None
    config = nginx_config_path([nginx], arguments)
    if not Path(config).is_file():
        return None
    return {
        "kind": "host-nginx",
        "target": "host",
        "runtime_config": config,
        "executable": nginx,
        "backend_ip": "127.0.0.1",
        "trusted_cidr": "127.0.0.1/32",
        "edge_port": port,
    }


def docker_containers() -> list[dict[str, Any]]:
    if not command_exists("docker"):
        return []
    listed = run(["docker", "ps", "-q"], check=False)
    containers: list[dict[str, Any]] = []
    for container_id in listed.stdout.split():
        inspected = run(["docker", "inspect", container_id], check=False)
        if inspected.returncode != 0:
            continue
        try:
            payload = json.loads(inspected.stdout)[0]
        except (json.JSONDecodeError, IndexError, TypeError):
            continue
        containers.append(payload)
    return containers


def docker_mapped_port(container: dict[str, Any], port: int) -> int | None:
    if container.get("HostConfig", {}).get("NetworkMode") == "host":
        init_pid = container.get("State", {}).get("Pid")
        if not isinstance(init_pid, int) or init_pid <= 0:
            return None
        try:
            container_root = os.stat(f"/proc/{init_pid}/root")
        except OSError:
            return None
        details = listener_details(port)
        for process_id in re.findall(r"pid=([0-9]+)", details):
            try:
                process_root = os.stat(f"/proc/{process_id}/root")
            except OSError:
                continue
            if (process_root.st_dev, process_root.st_ino) == (
                container_root.st_dev,
                container_root.st_ino,
            ):
                return port
        return None
    published = container.get("NetworkSettings", {}).get("Ports", {})
    for container_socket, bindings in published.items():
        match = re.fullmatch(r"([0-9]{1,5})/tcp", str(container_socket))
        if not match:
            continue
        if any(str(binding.get("HostPort", "")) == str(port) for binding in bindings or []):
            return int(match.group(1))
    return None


def docker_command(container_id: str, command: list[str]) -> subprocess.CompletedProcess[str]:
    return run(["docker", "exec", container_id] + command, check=False)


def docker_process_arguments(container: dict[str, Any]) -> list[str]:
    config = container.get("Config", {})
    command: list[str] = []
    entrypoint = config.get("Entrypoint") or []
    args = config.get("Cmd") or []
    if isinstance(entrypoint, str):
        command.append(entrypoint)
    else:
        command.extend(str(item) for item in entrypoint)
    if isinstance(args, str):
        command.extend(shlex.split(args))
    else:
        command.extend(str(item) for item in args)
    return command


def docker_network_route(container: dict[str, Any]) -> tuple[str, str]:
    if container.get("HostConfig", {}).get("NetworkMode") == "host":
        return "127.0.0.1", "127.0.0.1/32"
    networks = container.get("NetworkSettings", {}).get("Networks", {})
    for network in networks.values():
        gateway = str(network.get("Gateway") or "")
        prefix_length = network.get("IPPrefixLen")
        if gateway and isinstance(prefix_length, int):
            network_cidr = str(ipaddress.ip_network(f"{gateway}/{prefix_length}", strict=False))
            return gateway, network_cidr
    raise IntegrationError("cannot determine the Docker bridge gateway for the reverse proxy")


def docker_path_is_persistent(container: dict[str, Any], runtime_path: str) -> bool:
    runtime = Path(runtime_path)
    for mount in container.get("Mounts", []):
        destination = str(mount.get("Destination") or "")
        if not destination.startswith("/"):
            continue
        mounted = Path(destination)
        try:
            runtime.relative_to(mounted)
            return True
        except ValueError:
            continue
    return False


def docker_persistent_mounts(container: dict[str, Any]) -> list[str]:
    mounts: list[str] = []
    for mount in container.get("Mounts", []):
        destination = str(mount.get("Destination") or "")
        if destination.startswith("/"):
            mounts.append(destination)
    return sorted(set(mounts))


def docker_target(port: int) -> dict[str, Any] | None:
    for container in docker_containers():
        edge_port = docker_mapped_port(container, port)
        if edge_port is None:
            continue
        container_id = str(container.get("Id", ""))
        name = str(container.get("Name", "")).lstrip("/")
        arguments = docker_process_arguments(container)
        backend_ip, trusted_cidr = docker_network_route(container)
        labels = container.get("Config", {}).get("Labels", {}) or {}
        if labels.get(MANAGED_CADDY_LABEL) == "true":
            return {
                "kind": "managed-caddy",
                "target": name or container_id[:12],
                "backend_ip": backend_ip,
                "trusted_cidr": trusted_cidr,
                "edge_port": edge_port,
            }

        modules = docker_command(container_id, ["caddy", "list-modules"])
        if modules.returncode == 0 and re.search(r"(?m)^layer4(?:\.|$)", modules.stdout):
            adapter = option_value(arguments, "--adapter") or "caddyfile"
            if adapter != "caddyfile":
                continue
            config = validate_path(option_value(arguments, "--config") or "/etc/caddy/Caddyfile")
            exists = docker_command(container_id, ["test", "-f", config])
            if exists.returncode == 0 and docker_path_is_persistent(container, config):
                return {
                    "kind": "docker-caddy",
                    "target": name or container_id[:12],
                    "container_id": container_id,
                    "runtime_config": config,
                    "persistent_mounts": docker_persistent_mounts(container),
                    "backend_ip": backend_ip,
                    "trusted_cidr": trusted_cidr,
                    "edge_port": edge_port,
                }

        version = docker_command(container_id, ["nginx", "-V"])
        version_output = f"{version.stdout}\n{version.stderr}"
        if version.returncode == 0 and "--with-stream_ssl_preread_module" in version_output:
            config = nginx_config_path(
                ["docker", "exec", container_id, "nginx"],
                arguments,
            )
            exists = docker_command(container_id, ["test", "-f", config])
            if exists.returncode == 0 and docker_path_is_persistent(container, config):
                return {
                    "kind": "docker-nginx",
                    "target": name or container_id[:12],
                    "container_id": container_id,
                    "runtime_config": config,
                    "persistent_mounts": docker_persistent_mounts(container),
                    "backend_ip": backend_ip,
                    "trusted_cidr": trusted_cidr,
                    "edge_port": edge_port,
                }
    return None


def detect_target(port: int) -> dict[str, Any] | None:
    return host_caddy_target(port) or host_nginx_target(port) or docker_target(port)


def target_record(target: dict[str, Any]) -> str:
    fields = [
        str(target["kind"]),
        str(target["target"]),
        str(target["backend_ip"]),
        str(target["trusted_cidr"]),
        str(target["edge_port"]),
    ]
    if any("\t" in field or "\n" in field for field in fields):
        raise IntegrationError("detected edge metadata contains an invalid separator")
    return "\t".join(fields)


def container_id_for(target: dict[str, Any]) -> str:
    container_id = str(target.get("container_id") or "")
    if not re.fullmatch(r"[a-f0-9]{12,64}", container_id):
        raise IntegrationError("invalid Docker container identifier")
    return container_id


def target_path_is_persistent(target: dict[str, Any], runtime_path: str) -> bool:
    runtime = Path(runtime_path)
    for destination in target.get("persistent_mounts", []):
        try:
            runtime.relative_to(Path(str(destination)))
            return True
        except ValueError:
            continue
    return False


def read_target_file(target: dict[str, Any], runtime_path: str) -> str:
    runtime_path = validate_path(runtime_path)
    if target["kind"].startswith("host-"):
        return Path(runtime_path).read_text(encoding="utf-8")
    if not target_path_is_persistent(target, runtime_path):
        raise IntegrationError(
            f"Docker configuration {runtime_path} is not stored in a persistent mount"
        )
    container_id = container_id_for(target)
    with tempfile.TemporaryDirectory(prefix="tupoproxy-edge-read-") as temp_dir:
        local_path = Path(temp_dir) / "config"
        copied = run(
            ["docker", "cp", f"{container_id}:{runtime_path}", str(local_path)],
            check=False,
        )
        if copied.returncode != 0:
            raise IntegrationError(f"cannot read {runtime_path} from container {target['target']}")
        return local_path.read_text(encoding="utf-8")


def write_target_file(target: dict[str, Any], runtime_path: str, content: str) -> None:
    runtime_path = validate_path(runtime_path)
    if target["kind"].startswith("host-"):
        path = Path(runtime_path).resolve(strict=True)
        file_stat = path.stat()
        mode = file_stat.st_mode & 0o777
        temporary = path.with_name(f".{path.name}.tupoproxy.tmp")
        temporary.write_text(content, encoding="utf-8")
        os.chmod(temporary, mode)
        os.chown(temporary, file_stat.st_uid, file_stat.st_gid)
        os.replace(temporary, path)
        return
    if not target_path_is_persistent(target, runtime_path):
        raise IntegrationError(
            f"Docker configuration {runtime_path} is not stored in a persistent mount"
        )
    container_id = container_id_for(target)
    written = run(
        [
            "docker",
            "exec",
            "-i",
            "--user",
            "0",
            container_id,
            "sh",
            "-c",
            'cat > "$1"',
            "tupoproxy-edge",
            runtime_path,
        ],
        check=False,
        input_text=content,
    )
    if written.returncode != 0:
        raise IntegrationError(f"cannot update {runtime_path} in container {target['target']}")


def remove_managed_block(content: str) -> str:
    pattern = re.compile(
        rf"(?ms)^\s*{re.escape(BEGIN_MARKER)}\n.*?^\s*{re.escape(END_MARKER)}\n?"
    )
    return pattern.sub("", content)


def brace_delta(line: str) -> int:
    without_comment = line.split("#", 1)[0]
    escaped = False
    quoted = False
    delta = 0
    for char in without_comment:
        if escaped:
            escaped = False
            continue
        if char == "\\":
            escaped = True
        elif char == '"':
            quoted = not quoted
        elif not quoted and char == "{":
            delta += 1
        elif not quoted and char == "}":
            delta -= 1
    return delta


def caddy_block(
    tls_domain: str,
    backend: str,
    public_port: int = 443,
    indent: str = "",
) -> list[str]:
    layer4 = caddy_layer4_lines(tls_domain, backend, f"{indent}        ")
    return [
        f"{indent}{BEGIN_MARKER}",
        f"{indent}servers :{public_port} {{",
        f"{indent}    listener_wrappers {{",
        *layer4,
        f"{indent}        tls",
        f"{indent}    }}",
        f"{indent}}}",
        f"{indent}{END_MARKER}",
    ]


def caddy_layer4_lines(tls_domain: str, backend: str, indent: str) -> list[str]:
    return [
        f"{indent}layer4 {{",
        f"{indent}    @tupoproxy tls sni {tls_domain}",
        f"{indent}    route @tupoproxy {{",
        f"{indent}        # Preserve FakeTLS bytes; this route must never terminate TLS.",
        f"{indent}        proxy {{",
        f"{indent}            proxy_protocol v2",
        f"{indent}            upstream tcp/{backend}",
        f"{indent}        }}",
        f"{indent}    }}",
        f"{indent}}}",
    ]


def closing_brace_index(lines: list[str], opening_index: int) -> int:
    depth = 0
    for index in range(opening_index, len(lines)):
        depth += brace_delta(lines[index])
        if depth == 0:
            return index
    raise IntegrationError("cannot locate the end of a Caddy configuration block")


def caddy_server_matches(line: str, public_port: int) -> bool:
    directive = line.split("#", 1)[0].strip().removesuffix("{").strip()
    tokens = directive.split()
    if not tokens or tokens[0] != "servers":
        return False
    if len(tokens) == 1:
        return True
    return any(token.endswith(f":{public_port}") for token in tokens[1:])


def insert_into_caddy_servers(
    lines: list[str],
    server_start: int,
    tls_domain: str,
    backend: str,
) -> None:
    server_end = closing_brace_index(lines, server_start)
    depth = 0
    listener_start = None
    for index in range(server_start, server_end):
        current_depth = depth
        depth += brace_delta(lines[index])
        if current_depth == 1 and re.match(r"^\s*listener_wrappers\s*\{", lines[index]):
            listener_start = index
            break

    if listener_start is not None:
        listener_end = closing_brace_index(lines, listener_start)
        listener_text = "\n".join(lines[listener_start + 1 : listener_end])
        if re.search(r"(?m)^\s*layer4\s*\{", listener_text):
            raise IntegrationError(
                "the selected Caddy listener_wrappers already contain layer4 rules; merge them manually"
            )
        indent = lines[listener_start][: len(lines[listener_start]) - len(lines[listener_start].lstrip())]
        managed = [f"{indent}    {BEGIN_MARKER}"]
        managed.extend(caddy_layer4_lines(tls_domain, backend, f"{indent}    "))
        managed.append(f"{indent}    {END_MARKER}")
        insertion_index = listener_end
        depth = 0
        for index in range(listener_start, listener_end):
            current_depth = depth
            depth += brace_delta(lines[index])
            if current_depth == 1 and lines[index].strip() == "tls":
                insertion_index = index
                break
        lines[insertion_index:insertion_index] = managed
        return

    indent = lines[server_start][: len(lines[server_start]) - len(lines[server_start].lstrip())]
    managed = [f"{indent}    {BEGIN_MARKER}", f"{indent}    listener_wrappers {{"]
    managed.extend(caddy_layer4_lines(tls_domain, backend, f"{indent}        "))
    managed.extend(
        [
            f"{indent}        tls",
            f"{indent}    }}",
            f"{indent}    {END_MARKER}",
        ]
    )
    lines[server_end:server_end] = managed


def patch_caddy(content: str, tls_domain: str, backend: str, public_port: int) -> str:
    content = remove_managed_block(content)
    lines = content.splitlines()
    first_significant = next(
        (index for index, line in enumerate(lines) if line.strip() and not line.lstrip().startswith("#")),
        None,
    )
    if first_significant is not None and lines[first_significant].strip() == "{":
        closing_index = closing_brace_index(lines, first_significant)
        depth = 0
        matching_server = None
        for index in range(first_significant, closing_index):
            current_depth = depth
            depth += brace_delta(lines[index])
            if current_depth == 1 and caddy_server_matches(lines[index], public_port):
                matching_server = index
                break
        if matching_server is not None:
            insert_into_caddy_servers(lines, matching_server, tls_domain, backend)
            return "\n".join(lines).rstrip() + "\n"
        lines[closing_index:closing_index] = caddy_block(
            tls_domain, backend, public_port, "    "
        )
        return "\n".join(lines).rstrip() + "\n"

    managed = [BEGIN_MARKER, "{"]
    managed.extend(caddy_block(tls_domain, backend, public_port, "    ")[1:-1])
    managed.extend(["}", END_MARKER, ""])
    return "\n".join(managed) + content.lstrip("\n")


def nginx_dump(target: dict[str, Any]) -> str:
    config = str(target["runtime_config"])
    if target["kind"] == "host-nginx":
        result = run([str(target["executable"]), "-T", "-c", config], check=False)
    else:
        result = docker_command(container_id_for(target), ["nginx", "-T", "-c", config])
    if result.returncode != 0:
        raise IntegrationError(f"cannot inspect the active nginx configuration:\n{result.stderr}")
    return f"{result.stdout}\n{result.stderr}"


def nginx_config_files(dump: str) -> list[str]:
    paths: list[str] = []
    for match in re.finditer(r"(?m)^# configuration file (/[A-Za-z0-9_./-]+):$", dump):
        path = validate_path(match.group(1))
        if path not in paths:
            paths.append(path)
    return paths


def encode_original_line(line: str) -> str:
    return base64.urlsafe_b64encode(line.encode("utf-8")).decode("ascii")


def decode_original_line(value: str) -> str:
    try:
        return base64.urlsafe_b64decode(value.encode("ascii")).decode("utf-8")
    except (ValueError, UnicodeDecodeError) as error:
        raise IntegrationError("invalid managed nginx listen-line metadata") from error


def is_tcp_listen(line: str, public_port: int) -> bool:
    stripped = line.lstrip()
    if not stripped.startswith("listen ") or "quic" in stripped or NGINX_ORIGINAL_MARKER in line:
        return False
    directive = stripped.split(";", 1)[0]
    tokens = directive.split()
    if len(tokens) < 2:
        return False
    address = tokens[1]
    port = str(public_port)
    return bool(
        address == port
        or re.fullmatch(rf"(?:\*|0\.0\.0\.0|[0-9.]+):{port}", address)
        or re.fullmatch(rf"\[[0-9A-Fa-f:]+\]:{port}", address)
    )


def patch_nginx_listeners(
    content: str,
    public_port: int,
    internal_port: int,
) -> tuple[str, int, bool, bool]:
    output: list[str] = []
    changed = 0
    has_ipv4 = False
    has_ipv6 = False
    for line in content.splitlines():
        if not is_tcp_listen(line, public_port):
            output.append(line)
            continue
        stripped = line.lstrip()
        indent = line[: len(line) - len(stripped)]
        directive, separator, comment = stripped.partition(";")
        tokens = directive.split()
        original_address = tokens[1]
        ipv6 = original_address.startswith("[")
        tokens[1] = f"[::1]:{internal_port}" if ipv6 else f"127.0.0.1:{internal_port}"
        if "proxy_protocol" not in tokens[2:]:
            tokens.append("proxy_protocol")
        encoded = encode_original_line(line)
        suffix = f" {comment.strip()}" if separator and comment.strip() else ""
        output.append(
            f"{indent}{' '.join(tokens)}; # {NGINX_ORIGINAL_MARKER}{encoded}{suffix}"
        )
        changed += 1
        has_ipv4 = has_ipv4 or not ipv6
        has_ipv6 = has_ipv6 or ipv6
    return "\n".join(output).rstrip() + "\n", changed, has_ipv4, has_ipv6


def restore_nginx_listeners(content: str) -> str:
    output: list[str] = []
    pattern = re.compile(rf"{NGINX_ORIGINAL_MARKER}([A-Za-z0-9_=-]+)")
    for line in content.splitlines():
        match = pattern.search(line)
        output.append(decode_original_line(match.group(1)) if match else line)
    return "\n".join(output).rstrip() + "\n"


def nginx_stream_block(
    tls_domain: str,
    backend: str,
    web_backend: str,
    listen_ipv4: bool,
    listen_ipv6: bool,
    public_port: int,
) -> str:
    listen_lines = []
    if listen_ipv4:
        listen_lines.append(f"        listen {public_port};")
    if listen_ipv6:
        listen_lines.append(f"        listen [::]:{public_port};")
    listeners = "\n".join(listen_lines)
    return f"""
{BEGIN_MARKER}
stream {{
    map $ssl_preread_server_name $tupoproxy_upstream {{
        hostnames;
        {tls_domain} {backend};
        default {web_backend};
    }}

    server {{
{listeners}
        proxy_connect_timeout 5s;
        proxy_timeout 2m;
        proxy_protocol on;
        # ssl_preread inspects SNI without terminating the FakeTLS connection.
        proxy_pass $tupoproxy_upstream;
        ssl_preread on;
    }}
}}
{END_MARKER}
"""


def validate_target(target: dict[str, Any]) -> None:
    config = str(target["runtime_config"])
    kind = str(target["kind"])
    if kind == "host-caddy":
        result = run(
            [str(target["executable"]), "validate", "--config", config, "--adapter", "caddyfile"],
            check=False,
        )
    elif kind == "docker-caddy":
        result = docker_command(
            container_id_for(target),
            ["caddy", "validate", "--config", config, "--adapter", "caddyfile"],
        )
    elif kind == "host-nginx":
        result = run([str(target["executable"]), "-t", "-c", config], check=False)
    elif kind == "docker-nginx":
        result = docker_command(container_id_for(target), ["nginx", "-t", "-c", config])
    else:
        raise IntegrationError(f"unsupported integration target: {kind}")
    if result.returncode != 0:
        raise IntegrationError(f"reverse-proxy configuration validation failed:\n{result.stderr}")


def reload_target(target: dict[str, Any]) -> None:
    config = str(target["runtime_config"])
    kind = str(target["kind"])
    if kind == "host-caddy":
        result = run(
            [str(target["executable"]), "reload", "--config", config, "--adapter", "caddyfile"],
            check=False,
        )
    elif kind == "docker-caddy":
        result = docker_command(
            container_id_for(target),
            ["caddy", "reload", "--config", config, "--adapter", "caddyfile"],
        )
    elif kind == "host-nginx":
        result = run(
            [str(target["executable"]), "-s", "reload", "-c", config],
            check=False,
        )
    elif kind == "docker-nginx":
        result = docker_command(container_id_for(target), ["nginx", "-s", "reload", "-c", config])
    else:
        raise IntegrationError(f"unsupported integration target: {kind}")
    if result.returncode != 0:
        raise IntegrationError(f"reverse-proxy reload failed:\n{result.stderr}")


def metadata_path(state_dir: Path) -> Path:
    return state_dir / "edge-integration.json"


def save_metadata(state_dir: Path, metadata: dict[str, Any]) -> None:
    state_dir.mkdir(parents=True, exist_ok=True)
    path = metadata_path(state_dir)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.chmod(temporary, 0o600)
    os.replace(temporary, path)


def load_metadata(state_dir: Path) -> dict[str, Any] | None:
    path = metadata_path(state_dir)
    if not path.is_file():
        return None
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as error:
        raise IntegrationError("invalid saved edge-integration metadata") from error
    if not isinstance(value, dict):
        raise IntegrationError("invalid saved edge-integration metadata type")
    return value


def apply_existing(
    target: dict[str, Any],
    tls_domain: str,
    backend: str,
    public_port: int,
    state_dir: Path,
) -> None:
    originals: dict[str, str] = {}
    try:
        if target["kind"].endswith("caddy"):
            config = str(target["runtime_config"])
            originals[config] = read_target_file(target, config)
            write_target_file(
                target,
                config,
                patch_caddy(originals[config], tls_domain, backend, public_port),
            )
        else:
            dump = nginx_dump(target)
            if re.search(r"(?m)^\s*stream\s*\{", remove_managed_block(dump)):
                raise IntegrationError(
                    "nginx already has a custom stream context; automatic merging is unsafe"
                )
            config_files = nginx_config_files(dump)
            total_changed = 0
            has_ipv4 = False
            has_ipv6 = False
            for config_file in config_files:
                content = read_target_file(target, config_file)
                patched, changed, file_has_ipv4, file_has_ipv6 = patch_nginx_listeners(
                    content,
                    public_port,
                    DEFAULT_INTERNAL_HTTPS_PORT,
                )
                if changed:
                    originals[config_file] = content
                    write_target_file(target, config_file, patched)
                    total_changed += changed
                    has_ipv4 = has_ipv4 or file_has_ipv4
                    has_ipv6 = has_ipv6 or file_has_ipv6
            if total_changed == 0:
                raise IntegrationError(
                    f"no active nginx TCP/{public_port} listen directives were found"
                )
            root_config = str(target["runtime_config"])
            if root_config not in originals:
                originals[root_config] = read_target_file(target, root_config)
            root_content = read_target_file(target, root_config)
            root_content = remove_managed_block(root_content).rstrip() + "\n"
            web_backend = (
                f"127.0.0.1:{DEFAULT_INTERNAL_HTTPS_PORT}"
                if has_ipv4
                else f"[::1]:{DEFAULT_INTERNAL_HTTPS_PORT}"
            )
            write_target_file(
                target,
                root_config,
                root_content
                + nginx_stream_block(
                    tls_domain,
                    backend,
                    web_backend,
                    has_ipv4,
                    has_ipv6,
                    public_port,
                ),
            )

        validate_target(target)
        reload_target(target)
    except Exception:
        for config_file, content in originals.items():
            try:
                write_target_file(target, config_file, content)
            except Exception:
                pass
        try:
            validate_target(target)
            reload_target(target)
        except Exception:
            pass
        raise

    save_metadata(
        state_dir,
        {
            **target,
            "mode": "existing",
            "modified_files": sorted(originals),
            "tls_domain": tls_domain,
            "backend": backend,
        },
    )


def docker_bridge_route() -> tuple[str, str]:
    inspected = run(["docker", "network", "inspect", "bridge"], check=False)
    if inspected.returncode != 0:
        raise IntegrationError("cannot inspect the default Docker bridge network")
    try:
        payload = json.loads(inspected.stdout)[0]
        subnet = payload["IPAM"]["Config"][0]["Subnet"]
        gateway = payload["IPAM"]["Config"][0]["Gateway"]
    except (json.JSONDecodeError, IndexError, KeyError, TypeError) as error:
        raise IntegrationError("Docker bridge network has no usable IPv4 route") from error
    ipaddress.ip_address(gateway)
    ipaddress.ip_network(subnet)
    return str(gateway), str(subnet)


def managed_caddy_record() -> str:
    gateway, subnet = docker_bridge_route()
    return target_record(
        {
            "kind": "managed-caddy",
            "target": "tupoproxy-caddy",
            "backend_ip": gateway,
            "trusted_cidr": subnet,
            "edge_port": 443,
        }
    )


def managed_caddyfile(domain: str, tls_domain: str, backend: str) -> str:
    block = "\n".join(caddy_block(tls_domain, backend, 443, "    ")[1:-1])
    return f"""{{
{block}
}}

{domain} {{
    encode zstd gzip
    header Cache-Control "no-store"
    respond `<html><head><title>{domain}</title></head><body><h1>Welcome</h1></body></html>` 200
}}
"""


def managed_caddy_run_command(opt_dir: Path) -> list[str]:
    return [
        "docker",
        "run",
        "--detach",
        "--name",
        MANAGED_CADDY_CONTAINER,
        "--label",
        f"{MANAGED_CADDY_LABEL}=true",
        "--restart",
        "unless-stopped",
        "--add-host",
        "host.docker.internal:host-gateway",
        "--publish",
        "443:443/tcp",
        "--publish",
        "443:443/udp",
        "--volume",
        f"{opt_dir / 'Caddyfile'}:/etc/caddy/Caddyfile:ro",
        "--volume",
        f"{opt_dir / 'data'}:/data",
        "--volume",
        f"{opt_dir / 'config'}:/config",
        MANAGED_CADDY_IMAGE,
    ]


def restore_managed_caddy(
    opt_dir: Path,
    previous_caddyfile: str | None,
    backup_name: str | None,
) -> bool:
    run(["docker", "rm", "-f", MANAGED_CADDY_CONTAINER], check=False)
    if previous_caddyfile is not None:
        (opt_dir / "Caddyfile").write_text(previous_caddyfile, encoding="utf-8")
    if not backup_name:
        return True
    renamed = run(["docker", "rename", backup_name, MANAGED_CADDY_CONTAINER], check=False)
    if renamed.returncode != 0:
        return False
    restarted = run(["docker", "start", MANAGED_CADDY_CONTAINER], check=False)
    return restarted.returncode == 0


def provision_managed_caddy(
    domain: str,
    tls_domain: str,
    backend: str,
    state_dir: Path,
    opt_dir: Path,
) -> None:
    if not command_exists("docker"):
        raise IntegrationError("Docker is required for the managed Caddy fallback")
    marker = opt_dir / MANAGED_DIRECTORY_MARKER
    if opt_dir.exists() and not marker.is_file():
        raise IntegrationError(
            f"{opt_dir} already exists and is not managed by tupoproxy; move it or use an existing edge"
        )
    opt_dir.mkdir(parents=True, exist_ok=True)
    marker.write_text("Managed by tupoproxy.\n", encoding="utf-8")
    caddyfile = opt_dir / "Caddyfile"
    candidate_caddyfile = opt_dir / "Caddyfile.next"
    previous_caddyfile = caddyfile.read_text(encoding="utf-8") if caddyfile.is_file() else None
    dockerfile = f"""FROM caddy:{MANAGED_CADDY_VERSION}-builder AS builder
RUN xcaddy build --with github.com/mholt/caddy-l4@v{MANAGED_CADDY_L4_VERSION}

FROM caddy:{MANAGED_CADDY_VERSION}
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
"""
    (opt_dir / "Dockerfile").write_text(dockerfile, encoding="utf-8")
    candidate_caddyfile.write_text(
        managed_caddyfile(domain, tls_domain, backend), encoding="utf-8"
    )
    (opt_dir / "README.txt").write_text(
        "Managed by tupoproxy. Re-run install.sh to update this Caddy edge.\n",
        encoding="utf-8",
    )
    (opt_dir / "data").mkdir(exist_ok=True)
    (opt_dir / "config").mkdir(exist_ok=True)

    existing = run(["docker", "inspect", MANAGED_CADDY_CONTAINER], check=False)
    backup_name = None
    if existing.returncode == 0:
        try:
            labels = json.loads(existing.stdout)[0].get("Config", {}).get("Labels", {}) or {}
        except (json.JSONDecodeError, IndexError, TypeError) as error:
            candidate_caddyfile.unlink(missing_ok=True)
            raise IntegrationError("cannot inspect the existing tupoproxy-caddy container") from error
        if labels.get(MANAGED_CADDY_LABEL) != "true":
            candidate_caddyfile.unlink(missing_ok=True)
            raise IntegrationError(
                "container tupoproxy-caddy already exists but is not managed by tupoproxy"
            )
        backup_name = f"{MANAGED_CADDY_CONTAINER}-rollback"
        if run(["docker", "inspect", backup_name], check=False).returncode == 0:
            candidate_caddyfile.unlink(missing_ok=True)
            raise IntegrationError(
                f"rollback container {backup_name} already exists; remove it after checking its contents"
            )

    build = run(
        ["docker", "build", "--pull", "-t", MANAGED_CADDY_IMAGE, str(opt_dir)],
        check=False,
        capture=False,
    )
    if build.returncode != 0:
        candidate_caddyfile.unlink(missing_ok=True)
        raise IntegrationError("failed to build the managed Caddy image with caddy-l4")
    validated = run(
        [
            "docker",
            "run",
            "--rm",
            "--volume",
            f"{candidate_caddyfile}:/etc/caddy/Caddyfile:ro",
            MANAGED_CADDY_IMAGE,
            "validate",
            "--config",
            "/etc/caddy/Caddyfile",
            "--adapter",
            "caddyfile",
        ],
        check=False,
    )
    if validated.returncode != 0:
        candidate_caddyfile.unlink(missing_ok=True)
        raise IntegrationError(f"managed Caddy configuration is invalid:\n{validated.stderr}")
    os.replace(candidate_caddyfile, caddyfile)
    if backup_name:
        stopped = run(["docker", "stop", MANAGED_CADDY_CONTAINER], check=False)
        if stopped.returncode != 0:
            if previous_caddyfile is not None:
                caddyfile.write_text(previous_caddyfile, encoding="utf-8")
            run(["docker", "start", MANAGED_CADDY_CONTAINER], check=False)
            raise IntegrationError("cannot stop the previous managed Caddy container")
        renamed = run(
            ["docker", "rename", MANAGED_CADDY_CONTAINER, backup_name],
            check=False,
        )
        if renamed.returncode != 0:
            if previous_caddyfile is not None:
                caddyfile.write_text(previous_caddyfile, encoding="utf-8")
            run(["docker", "start", MANAGED_CADDY_CONTAINER], check=False)
            raise IntegrationError("cannot prepare the managed Caddy rollback container")
    started = run(managed_caddy_run_command(opt_dir), check=False)
    if started.returncode != 0:
        restored = restore_managed_caddy(opt_dir, previous_caddyfile, backup_name)
        suffix = "" if restored else " The previous container could not be restored."
        raise IntegrationError(
            f"failed to start the managed Caddy container:{suffix}\n{started.stderr}"
        )
    running = run(
        ["docker", "inspect", "--format", "{{.State.Running}}", MANAGED_CADDY_CONTAINER],
        check=False,
    )
    if running.returncode != 0 or running.stdout.strip() != "true":
        logs = run(["docker", "logs", MANAGED_CADDY_CONTAINER], check=False)
        restored = restore_managed_caddy(opt_dir, previous_caddyfile, backup_name)
        suffix = "" if restored else " The previous container could not be restored."
        raise IntegrationError(
            f"managed Caddy exited during startup:{suffix}\n{logs.stderr}{logs.stdout}"
        )
    if backup_name:
        removed = run(["docker", "rm", "-f", backup_name], check=False)
        if removed.returncode != 0:
            print(
                f"warning: new Caddy is running, but rollback container {backup_name} "
                "could not be removed",
                file=sys.stderr,
            )
    save_metadata(
        state_dir,
        {
            "mode": "managed",
            "kind": "managed-caddy",
            "target": MANAGED_CADDY_CONTAINER,
            "opt_dir": str(opt_dir),
            "domain": domain,
            "tls_domain": tls_domain,
            "backend": backend,
        },
    )


def rediscover_saved_target(metadata: dict[str, Any]) -> dict[str, Any]:
    kind = str(metadata.get("kind") or "")
    if kind.startswith("host-"):
        return metadata
    if kind.startswith("docker-"):
        target_name = str(metadata.get("target") or "")
        inspected = run(["docker", "inspect", target_name], check=False)
        if inspected.returncode != 0:
            raise IntegrationError(f"saved Docker reverse proxy {target_name} is not available")
        payload = json.loads(inspected.stdout)[0]
        metadata = dict(metadata)
        metadata["container_id"] = payload["Id"]
        metadata["persistent_mounts"] = docker_persistent_mounts(payload)
        return metadata
    raise IntegrationError(f"unsupported saved edge target: {kind}")


def remove_existing(metadata: dict[str, Any], state_dir: Path) -> None:
    target = rediscover_saved_target(metadata)
    originals: dict[str, str] = {}
    try:
        for config_file in metadata.get("modified_files", []):
            config_file = validate_path(str(config_file))
            current = read_target_file(target, config_file)
            originals[config_file] = current
            cleaned = remove_managed_block(current)
            if target["kind"].endswith("nginx"):
                cleaned = restore_nginx_listeners(cleaned)
            write_target_file(target, config_file, cleaned)
        validate_target(target)
        reload_target(target)
    except Exception:
        for config_file, content in originals.items():
            try:
                write_target_file(target, config_file, content)
            except Exception:
                pass
        try:
            validate_target(target)
            reload_target(target)
        except Exception:
            pass
        raise
    metadata_path(state_dir).unlink(missing_ok=True)


def remove_integration(state_dir: Path) -> None:
    metadata = load_metadata(state_dir)
    if not metadata:
        return
    if metadata.get("mode") == "managed":
        container_names = [
            MANAGED_CADDY_CONTAINER,
            f"{MANAGED_CADDY_CONTAINER}-rollback",
        ]
        for container_name in container_names:
            inspected = run(["docker", "inspect", container_name], check=False)
            if inspected.returncode != 0:
                continue
            try:
                labels = json.loads(inspected.stdout)[0].get("Config", {}).get("Labels", {}) or {}
            except (json.JSONDecodeError, IndexError, TypeError) as error:
                raise IntegrationError("cannot inspect the managed Caddy container") from error
            if labels.get(MANAGED_CADDY_LABEL) != "true":
                raise IntegrationError(
                    f"refusing to remove {container_name} because its ownership label is missing"
                )
            removed = run(
                ["docker", "rm", "-f", container_name],
                check=False,
                capture=False,
            )
            if removed.returncode != 0:
                raise IntegrationError(f"cannot remove the managed Caddy container {container_name}")
        metadata_path(state_dir).unlink(missing_ok=True)
        return
    remove_existing(metadata, state_dir)


def valid_domain(value: str) -> str:
    value = value.lower()
    if not re.fullmatch(r"(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}", value):
        raise argparse.ArgumentTypeError(f"invalid domain: {value}")
    return value


def valid_backend(value: str) -> str:
    if not re.fullmatch(r"(?:[A-Za-z0-9_.:-]+|\[[0-9A-Fa-f:]+\]):[0-9]{1,5}", value):
        raise argparse.ArgumentTypeError(f"invalid backend: {value}")
    port = int(value.rsplit(":", 1)[1])
    if not 1 <= port <= 65535:
        raise argparse.ArgumentTypeError(f"invalid backend port: {port}")
    return value


def parser() -> argparse.ArgumentParser:
    root = argparse.ArgumentParser(description=__doc__)
    subparsers = root.add_subparsers(dest="command", required=True)

    detect = subparsers.add_parser("detect")
    detect.add_argument("--port", type=int, default=443)

    managed = subparsers.add_parser("managed-record")
    managed.add_argument("--port", type=int, default=443)

    apply_command = subparsers.add_parser("apply")
    apply_command.add_argument("--port", type=int, default=443)
    apply_command.add_argument("--tls-domain", required=True, type=valid_domain)
    apply_command.add_argument("--backend", required=True, type=valid_backend)
    apply_command.add_argument("--state-dir", required=True, type=Path)

    provision = subparsers.add_parser("provision-caddy")
    provision.add_argument("--domain", required=True, type=valid_domain)
    provision.add_argument("--tls-domain", required=True, type=valid_domain)
    provision.add_argument("--backend", required=True, type=valid_backend)
    provision.add_argument("--state-dir", required=True, type=Path)
    provision.add_argument("--opt-dir", default=Path("/opt/caddy"), type=Path)

    remove = subparsers.add_parser("remove")
    remove.add_argument("--state-dir", required=True, type=Path)
    return root


def main() -> int:
    args = parser().parse_args()
    if args.command == "detect":
        target = detect_target(args.port)
        if not target:
            return 1
        print(target_record(target))
        return 0
    if args.command == "managed-record":
        if args.port != 443:
            raise IntegrationError("the managed Caddy fallback currently supports TCP/443 only")
        print(managed_caddy_record())
        return 0
    if args.command == "apply":
        target = detect_target(args.port)
        if not target:
            raise IntegrationError("the previously detected compatible reverse proxy is no longer available")
        if target.get("kind") == "managed-caddy":
            raise IntegrationError("the managed Caddy edge must be updated with provision-caddy")
        apply_existing(
            target,
            args.tls_domain,
            args.backend,
            int(target.get("edge_port", args.port)),
            args.state_dir,
        )
        return 0
    if args.command == "provision-caddy":
        provision_managed_caddy(
            args.domain,
            args.tls_domain,
            args.backend,
            args.state_dir,
            args.opt_dir,
        )
        return 0
    if args.command == "remove":
        remove_integration(args.state_dir)
        return 0
    raise IntegrationError("unknown command")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except IntegrationError as error:
        print(f"tupoproxy edge integration: {error}", file=sys.stderr)
        raise SystemExit(1)
    except (OSError, subprocess.SubprocessError) as error:
        print(f"tupoproxy edge integration: operating-system error: {error}", file=sys.stderr)
        raise SystemExit(1)
