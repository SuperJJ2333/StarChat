"""Deployment-compatibility regression (found by the production readiness rehearsal).

The production business API runs a revision whose `app.modules.moments.media` predates the
GIF container validator and the MIME→suffix map. The Moments bridge must therefore import and
behave correctly against **both** revisions: prefer the Moments module's own values when they
exist, and fall back to local equivalents when they do not (without the fallback the whole API
fails to start, because `app.main` imports the bridge).
"""

from __future__ import annotations

import importlib
from pathlib import Path

import pytest


def test_bridge_prefers_the_moments_module_constants() -> None:
    from app.modules import moments
    from app.modules.media import moments_bridge

    # When the module provides them, the bridge must use the module's values (no drift).
    assert (
        moments_bridge.IMAGE_SUFFIX_BY_MIME
        is getattr(moments.media, "IMAGE_SUFFIX_BY_MIME", None)
        or moments_bridge.IMAGE_SUFFIX_BY_MIME == moments.media.IMAGE_SUFFIX_BY_MIME
    )
    assert moments_bridge._validate_gif_container is getattr(
        moments.media, "validate_gif", None
    )


def test_bridge_imports_when_the_moments_module_lacks_the_newer_helpers(monkeypatch) -> None:
    """Simulates the deployed older revision: import must still succeed and stay safe."""

    from app.modules import moments
    from app.modules.media import moments_bridge

    monkeypatch.delattr(moments.media, "IMAGE_SUFFIX_BY_MIME", raising=False)
    monkeypatch.delattr(moments.media, "validate_gif", raising=False)
    try:
        reloaded = importlib.reload(moments_bridge)
        assert reloaded.IMAGE_SUFFIX_BY_MIME["image/jpeg"] == ".jpg"
        assert reloaded.IMAGE_SUFFIX_BY_MIME["image/gif"] == ".gif"
        assert reloaded._validate_gif_container is None
        # The allowlist, the size cap and the bridge's own format check must still apply.
        assert reloaded.ALLOWED_IMAGE_MIME == moments.media.ALLOWED_IMAGE_MIME
        assert reloaded.MAX_IMAGE_BYTES == moments.media.MAX_IMAGE_BYTES
        with pytest.raises(Exception):
            reloaded.MomentsMediaBridge._validate(
                mime="application/pdf", content=b"%PDF-1.4", purpose="MOMENT_IMAGE"
            )
        with pytest.raises(Exception):
            reloaded.MomentsMediaBridge._validate(
                mime="image/jpeg", content=b"GIF89a" + b"\x00" * 32, purpose="MOMENT_IMAGE"
            )
    finally:
        # Undo the simulated absence *before* reloading, otherwise the bridge would stay in
        # the fallback state for later tests in this process.
        monkeypatch.undo()
        importlib.reload(moments_bridge)


def test_bridge_uses_the_module_validator_when_present() -> None:
    """A malformed GIF must be rejected through the Moments validator when it exists."""

    from app.modules.media import moments_bridge
    from app.modules.media.moments_bridge import MomentsMediaBridge

    if moments_bridge._validate_gif_container is None:  # pragma: no cover - older revision
        pytest.skip("this revision has no GIF validator in the Moments module")
    with pytest.raises(Exception):
        MomentsMediaBridge._validate(
            mime="image/gif", content=b"GIF89a" + b"\x00" * 64, purpose="MOMENT_IMAGE"
        )


def test_avatar_backend_shape_is_still_the_deployed_one(platform) -> None:
    """Guard the premise of the two reconciler tests below.

    The deployed avatar store exposes ``put``/``get``/``delete``/``signed_read_url`` and keeps
    its directory behind a private ``_root``. It has no public ``root`` and no ``exists``. If
    that ever changes, the compatibility fallbacks below stop being exercised and this fails
    loudly instead of quietly passing.
    """

    backend = platform.storage
    assert not hasattr(backend, "root")
    assert not hasattr(backend, "exists")
    assert backend._root == Path(platform.root).resolve()


def test_reconciler_accepts_the_deployed_avatar_backend(platform) -> None:
    """Reconcile must work with the backend the API actually deploys against.

    The compatibility probe injected the production ``LocalPrivateObjectStorage`` into
    ``MediaReconciler`` and got ``AttributeError: no attribute 'root'``; that backend also has
    no ``exists`` probe. Reconcile is the one component that reads the object directory itself,
    so it resolves the directory from either spelling and falls back to the filesystem for
    existence.
    """

    from app.modules.media.reconcile import MediaReconciler

    platform.ingest(content=b"deployed-backend-shape" * 64)

    reconciler = MediaReconciler(platform.factory, backend=platform.storage)
    report = reconciler.run(dry_run=True)
    assert report.scanned_blobs == 1
    assert report.missing_files == ()
    assert report.invalidated == 0

    # Missing file without a row-level probe must still be detected through the directory.
    files = _platform_files(platform.root)
    assert len(files) == 1
    Path(files[0]).unlink()
    after = reconciler.run(dry_run=False)
    assert after.missing_files and after.invalidated == 1
    assert after.errors == ()


def test_reconciler_refuses_a_backend_without_a_known_directory() -> None:
    """No directory at all is a configuration error, not a silent no-op."""

    from app.core.errors import AppError
    from app.modules.media.reconcile import MediaReconciler

    class _Opaque:
        def put(self, key: str, content: bytes) -> None: ...

        def get(self, key: str) -> bytes:
            return b""

        def delete(self, key: str) -> None: ...

    with pytest.raises(AppError) as caught:
        MediaReconciler(lambda: None, backend=_Opaque())
    assert caught.value.code == "MEDIA_RECONCILE_ROOT_UNKNOWN"


def _platform_files(root: str) -> list[str]:
    found: list[str] = []
    for prefix in ("media/", "moments/media/"):
        base = Path(root) / prefix
        if base.is_dir():
            found.extend(
                str(path) for path in sorted(base.rglob("*")) if path.is_file()
            )
    return found
