from datetime import datetime, timezone


def recommendation_score(moment, *, like_count: int, comment_count: int, risk_count: int = 0) -> float:
    age_hours = max(0.0, (datetime.now(timezone.utc) - moment.created_at).total_seconds() / 3600)
    return like_count * 2 + comment_count * 3 - age_hours / 24 - risk_count * 20
