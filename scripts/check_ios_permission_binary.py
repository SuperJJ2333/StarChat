"""Reject iOS candidates containing permission_handler placeholder strategies."""
from pathlib import Path
import sys

REQUIRED_METHODS = (
    "-[AudioVideoPermissionStrategy requestPermission:completionHandler:errorHandler:]",
    "+[AudioVideoPermissionStrategy checkPermissionStatus:]",
    "-[PhotoPermissionStrategy requestPermission:completionHandler:errorHandler:]",
    "-[NotificationPermissionStrategy requestPermission:completionHandler:errorHandler:]",
)


def verify_permission_binary(binary: bytes) -> None:
    for method in REQUIRED_METHODS:
        if method.encode() + b"\0" not in binary + b"\0":
            raise ValueError("Native permission implementation missing: " + method)


if __name__ == "__main__":
    verify_permission_binary(Path(sys.argv[1]).read_bytes())
    print("Native permission implementations: PASS (camera/microphone/photos/notifications)")
