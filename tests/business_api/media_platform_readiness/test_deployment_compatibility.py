"""Deployment-compatibility regression (found by the production readiness rehearsal).

The production business API runs a revision whose `app.modules.moments.media` predates the
GIF container validator and the MIME→suffix map. The Moments bridge must therefore import and
behave correctly against **both** revisions: prefer the Moments module's own values when they
exist, and fall back to local equivalents when they do not (without the fallback the whole API
fails to start, because `app.main` imports the bridge).
"""

from __future__ import annotations

import importlib

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
