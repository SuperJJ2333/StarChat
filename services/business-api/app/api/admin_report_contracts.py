"""Additive OpenAPI contracts for read-only administrator evidence."""
from typing import Annotated, Literal

from pydantic import BaseModel, Field

Amount = Annotated[str, Field(pattern=r'^-?\d+\.\d{2}$')]


class RegistrationDay(BaseModel):
    date: str
    value: int


class PointSupply(BaseModel):
    total: Amount
    issued: Amount
    returned: Amount
    holdings: Amount
    platform_fees: Amount
    balanced: bool
    anomalies: list[str]
    as_of: str


class AdminOverview(BaseModel):
    registered_users: int
    active_users: int
    online_customers: int
    pending_withdrawals: int
    today_point_volume: Amount
    brand: str
    registration_trend: list[RegistrationDay]
    registration_timezone: Literal['Asia/Hong_Kong']
    registration_today_partial: bool
    point_supply: PointSupply


class PointIssuanceItem(BaseModel):
    id: str
    transaction_id: str
    created_at: str
    kind: Literal['issued', 'returned']
    amount: Amount
    actor_id: str
    reason_code: str
    scope: str
    reversal_of_id: str | None
    audit_ids: list[str]
    anomalies: list[str]


class PointIssuancePage(BaseModel):
    items: list[PointIssuanceItem]
    next_cursor: str | None


class PointIssuanceEntry(BaseModel):
    id: str
    account_id: str
    asset: str
    amount: Amount


class PointIssuanceAudit(BaseModel):
    id: str
    actor_id: str | None
    action: str
    resource_type: str
    resource_id: str
    reason_code: str
    created_at: str


class PointIssuanceDetail(PointIssuanceItem):
    entries: list[PointIssuanceEntry]
    audits: list[PointIssuanceAudit]
