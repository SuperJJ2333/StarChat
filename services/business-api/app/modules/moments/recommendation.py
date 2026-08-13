from datetime import datetime, timezone


def recommendation_score(moment, *, like_count: int, comment_count: int, risk_count: int = 0) -> float:
    created_at = moment.created_at if moment.created_at.tzinfo else moment.created_at.replace(tzinfo=timezone.utc)
    age_hours = max(0.0, (datetime.now(timezone.utc) - created_at).total_seconds() / 3600)
    return like_count * 2 + comment_count * 3 - age_hours / 24 - risk_count * 20
