"""Durable job queue (Procrastinate, stored in Postgres) and the nightly refresh schedule."""

import logging
from datetime import date, timedelta

import procrastinate

from app.config import settings
from app.db import pool
from app.pipeline import run_job

log = logging.getLogger(__name__)

queue = procrastinate.App(connector=procrastinate.PsycopgConnector(conninfo=settings.database_url))


@queue.task(
    name="process_field",
    # Retries cover transient STAC/S3 outages; per-scene read errors are already skipped inside the job.
    retry=procrastinate.RetryStrategy(max_attempts=3, wait=120),
)
def process_field_task(job_id: str, field_id: str, start: str, end: str, force: bool = False) -> None:
    run_job(job_id, field_id, date.fromisoformat(start), date.fromisoformat(end), force)


def enqueue_field(field_id: str, start: date, end: date, force: bool = False) -> dict | None:
    """Create a processing_jobs row and queue it. Returns None if the field already has a job queued."""
    with pool.connection() as conn:
        job = conn.execute(
            "INSERT INTO processing_jobs (field_id) VALUES (%s) RETURNING id, status", (field_id,)
        ).fetchone()
    try:
        process_field_task.configure(
            lock=field_id,           # never process the same field twice at once
            queueing_lock=field_id,  # and never queue it twice
        ).defer(job_id=str(job["id"]), field_id=field_id, start=start.isoformat(), end=end.isoformat(), force=force)
    except procrastinate.exceptions.AlreadyEnqueued:
        with pool.connection() as conn:
            conn.execute("DELETE FROM processing_jobs WHERE id = %s", (job["id"],))
        return None
    return job


@queue.periodic(cron=settings.nightly_cron, periodic_id="nightly_refresh")
@queue.task(name="nightly_refresh", queueing_lock="nightly_refresh")
def nightly_refresh(timestamp: int) -> None:
    """Queue every field for the last few days; already-stored dates are skipped by the pipeline."""
    end = date.today()
    start = end - timedelta(days=settings.nightly_lookback_days)
    with pool.connection() as conn:
        field_ids = [str(r["id"]) for r in conn.execute("SELECT id FROM farm_fields").fetchall()]
    queued = sum(enqueue_field(fid, start, end) is not None for fid in field_ids)
    log.info("nightly refresh: queued %d of %d fields", queued, len(field_ids))
