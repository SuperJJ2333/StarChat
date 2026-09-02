import os
import sys

sys.path.insert(0, "/opt/business-api")

from sqlalchemy import create_engine, inspect

from app.core.database import Base
from app.modules.ledger.models import LedgerEntry, LedgerTransaction  # noqa
from app.modules.identity import models as identity_models  # noqa
from app.modules.friendship import models as friendship_models  # noqa
from app.modules.redpacket import models as redpacket_models  # noqa
from app.modules.transfer import models as transfer_models  # noqa
from app.modules.settings.models import AppSetting  # noqa
from app.modules.audit.models import AuditEvent  # noqa

engine = create_engine(os.environ["BUSINESS_DATABASE_URL"])
inspector = inspect(engine)

missing = []
for table in Base.metadata.sorted_tables:
    if not inspector.has_table(table.name):
        missing.append(f"TABLE {table.name} missing entirely")
        continue
    existing = {col["name"] for col in inspector.get_columns(table.name)}
    for column in table.columns:
        if column.name not in existing:
            missing.append(f"COLUMN {table.name}.{column.name} missing")

if missing:
    print("DRIFT FOUND:")
    for item in missing:
        print(" -", item)
else:
    print("NO DRIFT: all model tables/columns exist in production")
