import argparse
import json
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[1]
BUSINESS_API = ROOT / "services" / "business-api"
CONTRACT_PATH = ROOT / "packages" / "api-contracts" / "openapi" / "liuhetong-v1.yaml"

if str(BUSINESS_API) not in sys.path:
    sys.path.insert(0, str(BUSINESS_API))

from app.core.config import Settings  # noqa: E402
from app.main import create_app  # noqa: E402


def build_document() -> dict:
    settings = Settings(
        environment="test",
        database_url="sqlite+pysqlite:///:memory:",
        redis_url="redis://localhost:6379/15",
    )
    return create_app(settings).openapi()


def render_document(document: dict) -> str:
    # JSON is a strict, deterministic subset of YAML 1.2.
    return json.dumps(document, ensure_ascii=False, indent=2, sort_keys=True) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description="Export the 六合通 OpenAPI contract")
    parser.add_argument("--check", action="store_true", help="fail when the contract has drifted")
    args = parser.parse_args()
    rendered = render_document(build_document())

    if args.check:
        if not CONTRACT_PATH.exists() or CONTRACT_PATH.read_text(encoding="utf-8") != rendered:
            print(f"OpenAPI contract drift detected: {CONTRACT_PATH}", file=sys.stderr)
            return 1
        print("OpenAPI contract: PASS")
        return 0

    CONTRACT_PATH.parent.mkdir(parents=True, exist_ok=True)
    CONTRACT_PATH.write_text(rendered, encoding="utf-8", newline="\n")
    print(f"Wrote {CONTRACT_PATH}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
