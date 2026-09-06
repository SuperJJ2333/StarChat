#!/usr/bin/env python3
"""Copy the nginx certificate pair into coturn's restricted Linux-only mount.

Run as root after certificate renewal and before restarting only coturn. This
helper never prints certificate material and never changes the source files.
"""
import argparse
import os
from pathlib import Path
import shutil
import ssl
import tempfile


def validate_pair(certificate: Path, private_key: Path) -> None:
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    # Certificate automation must fail rather than prompt on an encrypted key.
    context.load_cert_chain(str(certificate), str(private_key), password="")


def sync_certificates(source: Path, destination: Path, gid: int = 65534) -> None:
    source, destination = source.resolve(), destination.resolve()
    if source == destination or source in destination.parents:
        raise ValueError("TURN certificate destination must be separate from nginx")
    validate_pair(source / "fullchain.pem", source / "privkey.pem")
    destination.parent.mkdir(parents=True, exist_ok=True)
    # Staging starts at 0700, so even certificate-copy failures cannot expose keys.
    with tempfile.TemporaryDirectory(prefix=".turn-certs-", dir=destination.parent) as temporary:
        staging = Path(temporary)
        for name, mode in (("fullchain.pem", 0o644), ("privkey.pem", 0o640)):
            path = staging / name
            shutil.copyfile(source / name, path)
            os.chown(path, 0, gid)
            os.chmod(path, mode)
        # Validate the copied snapshot in case renewal changed the source mid-copy.
        validate_pair(staging / "fullchain.pem", staging / "privkey.pem")
        destination.mkdir(mode=0o750, exist_ok=True)
        os.chown(destination, 0, gid)
        os.chmod(destination, 0o750)
        # Keep the mounted directory inode stable. Coturn loads the pair only on
        # restart; the documented hook restarts only after both replaces succeed.
        for name in ("fullchain.pem", "privkey.pem"):
            os.replace(staging / name, destination / name)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path("/opt/starchat/data/nginx/certs"))
    parser.add_argument("--destination", type=Path, default=Path("/opt/starchat/data/coturn/certs"))
    parser.add_argument("--gid", type=int, default=65534, help="coturn nogroup numeric GID")
    args = parser.parse_args()
    if os.name != "posix" or os.geteuid() != 0:
        parser.error("run on Linux as root")
    try:
        sync_certificates(args.source, args.destination, args.gid)
    except (OSError, ValueError, ssl.SSLError):
        parser.exit(1, "TURN certificate synchronization failed; coturn was not restarted.\n")
    print("TURN certificate pair synchronized with restricted group access; restart coturn to load it.")


if __name__ == "__main__":
    main()
