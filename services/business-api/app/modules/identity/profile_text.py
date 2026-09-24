"""Shared profile text boundaries for registration and profile updates."""

import regex


MAX_PROFILE_RAW_CODEPOINTS = 512
MAX_NICKNAME_GRAPHEMES = 12
MAX_SIGNATURE_GRAPHEMES = 20
_GRAPHEME = regex.compile(r"\X")


def visible_length(value: str) -> int:
    """Count Unicode extended grapheme clusters, including joined emoji as one."""
    return sum(1 for _ in _GRAPHEME.finditer(value))


def valid_nickname(value: str) -> bool:
    return (
        bool(value)
        and len(value) <= MAX_PROFILE_RAW_CODEPOINTS
        and visible_length(value) <= MAX_NICKNAME_GRAPHEMES
    )


def valid_signature(value: str | None) -> bool:
    return value is None or (
        len(value) <= MAX_PROFILE_RAW_CODEPOINTS
        and visible_length(value) <= MAX_SIGNATURE_GRAPHEMES
    )


def registration_nickname(nickname: str | None, username: str) -> str:
    """Keep legacy empty-input fallback while bounding the generated default."""
    if nickname:
        return nickname.strip()
    return "".join(
        match.group(0)
        for index, match in enumerate(_GRAPHEME.finditer(username.strip()))
        if index < MAX_NICKNAME_GRAPHEMES
    )
