"""Published schema for draft daily wallet ledger evidence."""
from datetime import date, datetime
from typing import Literal

from pydantic import BaseModel, Field


class ReportAccount(BaseModel):
    asset: str
    account: str
    opening: str
    increase: str
    decrease: str
    closing: str


class ReportEntry(BaseModel):
    source: Literal['wallet', 'ledger']
    id: str
    transaction_id: str
    account: str
    asset: str
    amount: str
    created_at: datetime
    reason_code: str | None
    scope: str | None
    period: Literal['opening', 'movement']


class ReportImbalance(BaseModel):
    source: Literal['wallet', 'ledger']
    transaction_id: str
    asset: str
    amount: str


class ReportIntegrity(BaseModel):
    balanced: bool
    missing_transaction_metadata: bool
    entry_count: int
    transaction_count: int
    imbalances: list[ReportImbalance]


class DailyWalletReport(BaseModel):
    day: date
    timezone: Literal['Asia/Hong_Kong']
    start: datetime
    end: datetime
    finalized: Literal[False]
    accounts: list[ReportAccount]
    entries: list[ReportEntry]
    integrity: ReportIntegrity
    digest: str = Field(pattern=r'^[a-f0-9]{64}$',
        description='SHA256 of canonical captured JSON excluding digest; not an external audit signature.')
