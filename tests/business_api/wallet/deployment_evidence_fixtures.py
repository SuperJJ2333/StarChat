"""Model the root-owned fixture artifact without elevating the test runner."""
import os
from types import SimpleNamespace

from app.modules.wallet import handover_deployment


def trust_fixture_owner(monkeypatch, path):
    system = handover_deployment.os
    identity = path.stat()

    def fixture_fstat(descriptor):
        metadata = system.fstat(descriptor)
        if (metadata.st_dev, metadata.st_ino) != (identity.st_dev, identity.st_ino):
            return metadata
        fields = list(metadata)
        fields[4] = 0  # Only ownership of this synthetic artifact is modelled.
        return os.stat_result(fields)

    monkeypatch.setattr(handover_deployment, 'os', SimpleNamespace(
        name=system.name, open=system.open, fdopen=system.fdopen,
        O_RDONLY=system.O_RDONLY, O_NOFOLLOW=getattr(system, 'O_NOFOLLOW', 0),
        fstat=fixture_fstat,
    ))
