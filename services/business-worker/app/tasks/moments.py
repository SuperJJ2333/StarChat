from sqlalchemy import select

from app.modules.moments.models import Moment


class MomentsModerationTask:
    """Deterministic sandbox scanner; production adapters can replace the check."""

    def __init__(self, session_factory):
        self.factory = session_factory

    def run_batch(self, *, limit: int = 100) -> dict[str, int]:
        published = rejected = 0
        with self.factory.begin() as session:
            rows = session.scalars(
                select(Moment).where(Moment.status == "PENDING_REVIEW")
                .order_by(Moment.created_at, Moment.id).limit(limit).with_for_update(skip_locked=True)
            ).all()
            for moment in rows:
                unsafe = any(not str(url).lower().split("?", 1)[0].endswith((".jpg", ".jpeg", ".png", ".webp")) for url in moment.image_urls)
                moment.status = "REJECTED" if unsafe else "PUBLISHED"
                rejected += int(unsafe)
                published += int(not unsafe)
        return {"published": published, "rejected": rejected}
