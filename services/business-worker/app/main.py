import logging
import os
from signal import SIGINT, SIGTERM, signal
from threading import Event

from app.core.config import Settings
from app.core.database import create_engine, create_session_factory
from app.core.outbox import OutboxConsumer
from worker import Worker


def main() -> None:
    logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
    settings = Settings()
    engine = create_engine(settings)
    consumer = OutboxConsumer(create_session_factory(engine))
    stop_event = Event()

    def request_stop(_signum, _frame) -> None:
        stop_event.set()

    signal(SIGTERM, request_stop)
    signal(SIGINT, request_stop)

    worker = Worker(
        consumer=consumer,
        handlers={},
        worker_id=os.getenv("WORKER_ID", "business-worker-1"),
        heartbeat_path=os.getenv("WORKER_HEARTBEAT_PATH", "/tmp/liuhetong-worker-heartbeat"),
    )
    try:
        worker.run_forever(
            stop_event=stop_event,
            poll_interval_seconds=float(os.getenv("WORKER_POLL_INTERVAL_SECONDS", "1")),
            limit=int(os.getenv("WORKER_BATCH_SIZE", "50")),
        )
    finally:
        engine.dispose()


if __name__ == "__main__":
    main()
