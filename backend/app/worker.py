"""Queue worker entrypoint: python -m app.worker"""

import logging

import psycopg

from app.config import settings
from app.db import pool
from app.tasks import queue


def ensure_queue_schema() -> None:
    with psycopg.connect(settings.database_url) as conn:
        exists = conn.execute("SELECT to_regclass('procrastinate_jobs') IS NOT NULL").fetchone()[0]
    if not exists:
        with queue.open():
            queue.schema_manager.apply_schema()
        logging.info("applied procrastinate schema")


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    ensure_queue_schema()
    pool.open()
    queue.run_worker(concurrency=settings.worker_concurrency)


if __name__ == "__main__":
    main()
