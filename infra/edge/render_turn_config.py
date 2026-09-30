"""Render a protected coturn config without passing secrets through argv or env."""
from __future__ import annotations

import argparse
import ipaddress
import os
from pathlib import Path
import re
import stat
import tempfile

TEMPLATE = Path(__file__).with_name("turnserver.conf.template")
PRIVATE_NETWORKS = tuple(ipaddress.ip_network(network) for network in ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16"))


def _private_file(path: Path) -> bytes:
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
    if path.is_symlink():
        raise ValueError("secret input must be a regular protected file")
    descriptor = os.open(path, flags)
    try:
        info = os.fstat(descriptor)
        if not stat.S_ISREG(info.st_mode) or info.st_size > 256:
            raise ValueError("secret input must be a bounded regular file")
        if os.name == "posix" and (info.st_mode & 0o077 or info.st_uid != os.geteuid()):
            raise ValueError("secret input must be owner-only and owned by the renderer")
        return os.read(descriptor, 257)
    finally:
        os.close(descriptor)


def render(secret_file: Path, destination: Path, *, realm: str, public_ip: str, private_ip: str) -> None:
    """Validate first, then atomically install an owner-only configuration."""
    secret_file, destination = Path(secret_file), Path(destination)
    if secret_file.resolve() == destination.resolve():
        raise ValueError("secret and configuration must be separate paths")
    if destination.is_symlink() or destination.parent.is_symlink():
        raise ValueError("configuration paths must not be symbolic links")
    if not re.fullmatch(r"(?=.{1,253}$)[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?", realm) or ".." in realm:
        raise ValueError("invalid TURN realm")
    public = ipaddress.IPv4Address(public_ip)
    private = ipaddress.IPv4Address(private_ip)
    if not public.is_global or not any(private in network for network in PRIVATE_NETWORKS):
        raise ValueError("TURN requires a public IPv4 and an RFC1918 local IPv4")
    try:
        secret = _private_file(secret_file).decode("ascii").removesuffix("\n")
    except UnicodeDecodeError:
        raise ValueError("invalid TURN secret format") from None
    if not re.fullmatch(r"[A-Za-z0-9_+/=-]{32,128}", secret):
        raise ValueError("invalid TURN secret format")
    config = TEMPLATE.read_text(encoding="utf-8")
    for name, value in (("PRIVATE_IP", str(private)), ("PUBLIC_IP", str(public)), ("REALM", realm), ("AUTH_SECRET", secret)):
        config = config.replace("{{" + name + "}}", value)
    if "{{" in config or "}}" in config:
        raise ValueError("unresolved TURN template token")
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    if os.name == "posix":
        info = destination.parent.stat()
        if info.st_mode & 0o077 or info.st_uid != os.geteuid():
            raise ValueError("configuration parent must be owner-only and owned by the renderer")
    descriptor, temporary = tempfile.mkstemp(prefix=".turn-config-", dir=destination.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as output:
            output.write(config)
            output.flush()
            os.fsync(output.fileno())
        os.chmod(temporary, 0o600)
        os.replace(temporary, destination)
    finally:
        Path(temporary).unlink(missing_ok=True)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--secret-file", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--realm", required=True)
    parser.add_argument("--public-ip", required=True)
    parser.add_argument("--private-ip", required=True)
    arguments = parser.parse_args()
    try:
        render(arguments.secret_file, arguments.output, realm=arguments.realm, public_ip=arguments.public_ip, private_ip=arguments.private_ip)
    except (OSError, ValueError):
        parser.exit(1, "TURN configuration rendering rejected; inspect protected inputs and permissions\n")
    print("TURN configuration rendered without exporting secret material")


if __name__ == "__main__":
    main()
