"""Transactional generation state. This is the only authoritative job writer."""
from __future__ import annotations

import base64
import fcntl
import hashlib
import json
import os
import sqlite3
import threading
import time
import uuid
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Mapping

from .contracts import GenerationError

TERMINAL = {"succeeded", "cancelled", "interrupted", "failed"}
STATES = TERMINAL | {"queued", "recovery_hold", "preparing", "running", "finalizing",
                     "retrieval_pending", "cancel_requested", "submission_unknown"}
TRANSITIONS = {
    "queued": {"preparing", "recovery_hold", "cancelled", "failed"},
    "recovery_hold": {"queued", "cancelled", "failed"},
    "preparing": {"running", "finalizing", "cancel_requested", "failed", "interrupted", "submission_unknown", "retrieval_pending"},
    "running": {"finalizing", "cancel_requested", "failed", "interrupted", "submission_unknown", "retrieval_pending"},
    "finalizing": {"succeeded", "cancel_requested", "failed", "interrupted", "retrieval_pending"},
    "retrieval_pending": {"finalizing", "cancel_requested", "failed"},
    "cancel_requested": {"cancelled", "submission_unknown", "retrieval_pending"},
    "submission_unknown": {"cancel_requested", "retrieval_pending", "finalizing", "failed"},
}


def encode(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False)


def fingerprint(value: Any) -> str:
    return hashlib.sha256(encode(value).encode()).hexdigest()


def identifier() -> str:
    return str(uuid.uuid4())


class GenerationRepository:
    def __init__(self, root: Path, *, now=time.time):
        self.root = root.expanduser().resolve()
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self._now = now
        self.lock = threading.RLock()
        self._lock_file = open(self.root / ".scheduler.lock", "a+b")
        try:
            fcntl.flock(self._lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError as error:
            self._lock_file.close()
            raise GenerationError("store_in_use", "Another Nativ generation server owns this library.", status=503) from error
        self.connection = None
        self._closed = False
        try:
            self.connection = sqlite3.connect(self.root / "jobs.sqlite", isolation_level=None, check_same_thread=False)
            self.connection.row_factory = sqlite3.Row
            self.connection.execute("PRAGMA journal_mode=WAL")
            self.connection.execute("PRAGMA synchronous=FULL")
            self.connection.execute("PRAGMA busy_timeout=5000")
            version = self.connection.execute("PRAGMA user_version").fetchone()[0]
            if version not in (0, 1):
                self.close()
                raise GenerationError("unsupported_store_version", "This media library requires a newer Nativ version.", status=503)
            self.connection.executescript("""
              CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
              CREATE TABLE IF NOT EXISTS sessions(id TEXT PRIMARY KEY,modality TEXT NOT NULL,title TEXT NOT NULL,
                hidden INTEGER NOT NULL DEFAULT 0,created_at REAL NOT NULL,updated_at REAL NOT NULL);
              CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY,modality TEXT NOT NULL,session_id TEXT NOT NULL,
                created_at REAL NOT NULL,updated_at REAL NOT NULL,state TEXT NOT NULL,attempt_id TEXT,data TEXT NOT NULL);
              CREATE INDEX IF NOT EXISTS jobs_modality ON jobs(modality,created_at,id);
              CREATE TABLE IF NOT EXISTS idempotency(modality TEXT NOT NULL,key TEXT NOT NULL,request_hash TEXT NOT NULL,
                job_id TEXT NOT NULL,expires_at REAL,PRIMARY KEY(modality,key));
              CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY AUTOINCREMENT,job_id TEXT NOT NULL,
                type TEXT NOT NULL,data TEXT NOT NULL,created_at REAL NOT NULL);
              CREATE INDEX IF NOT EXISTS job_events ON events(job_id,id);
              CREATE TABLE IF NOT EXISTS assets(id TEXT PRIMARY KEY,job_id TEXT NOT NULL,modality TEXT NOT NULL,
                relative_path TEXT NOT NULL,filename TEXT NOT NULL,mime_type TEXT NOT NULL,byte_size INTEGER NOT NULL,
                sha256 TEXT NOT NULL,created_at REAL NOT NULL,trashed INTEGER NOT NULL DEFAULT 0,
                metadata TEXT NOT NULL,revision INTEGER NOT NULL DEFAULT 1);
              CREATE TABLE IF NOT EXISTS asset_references(asset_id TEXT NOT NULL,id TEXT NOT NULL,
                state TEXT NOT NULL,revision INTEGER NOT NULL,owner TEXT NOT NULL,updated_at REAL NOT NULL,
                PRIMARY KEY(asset_id,id));
              CREATE TABLE IF NOT EXISTS inputs(id TEXT PRIMARY KEY,relative_path TEXT NOT NULL,metadata TEXT NOT NULL,
                created_at REAL NOT NULL,revision INTEGER NOT NULL DEFAULT 1);
              CREATE TABLE IF NOT EXISTS input_usages(input_id TEXT NOT NULL,job_id TEXT NOT NULL,transform TEXT NOT NULL,
                PRIMARY KEY(input_id,job_id));
              CREATE TABLE IF NOT EXISTS publications(job_id TEXT PRIMARY KEY,attempt_id TEXT NOT NULL,
                asset_id TEXT NOT NULL,data TEXT NOT NULL);
              PRAGMA user_version=1;
            """)
            self.connection.execute("INSERT OR IGNORE INTO meta VALUES('store_id',?)", (identifier(),))
            self.store_id = self.connection.execute("SELECT value FROM meta WHERE key='store_id'").fetchone()[0]
        except BaseException:
            # Tracebacks can retain this partially constructed instance. Never
            # leave the scheduler flock or SQLite connection owned by that frame.
            try: self.close()
            except Exception: pass
            raise

    def close(self) -> None:
        with self.lock:
            if getattr(self, "_closed", False): return
            self._closed = True
            try:
                connection = getattr(self, "connection", None)
                if connection is not None: connection.close()
            finally:
                if not self._lock_file.closed:
                    try: fcntl.flock(self._lock_file, fcntl.LOCK_UN)
                    finally: self._lock_file.close()

    @contextmanager
    def transaction(self):
        with self.lock:
            self.connection.execute("BEGIN IMMEDIATE")
            try:
                yield
                self.connection.execute("COMMIT")
            except BaseException:
                self.connection.execute("ROLLBACK")
                raise

    def _session(self, row) -> dict:
        return dict(row, store_id=self.store_id, hidden=bool(row["hidden"]))

    def _create_session(self, modality: str, title: str = "Untitled") -> dict:
        sid, now = identifier(), self._now()
        self.connection.execute("INSERT INTO sessions VALUES(?,?,?,?,?,?)", (sid, modality, title[:200], 0, now, now))
        return self._session(self.connection.execute("SELECT * FROM sessions WHERE id=?", (sid,)).fetchone())

    def create_session(self, modality: str, title: str = "Untitled") -> dict:
        with self.transaction(): return self._create_session(modality, title)

    def patch_session(self, modality: str, session_id: str, changes: Mapping) -> dict:
        if set(changes) - {"title", "hidden"}:
            raise GenerationError("unsupported_field", "Only the session title and visibility can be changed.")
        if "title" in changes and (not isinstance(changes["title"], str) or len(changes["title"]) > 200):
            raise GenerationError("invalid_title", "A session title must be at most 200 characters.", field="title")
        if "hidden" in changes and type(changes["hidden"]) is not bool:
            raise GenerationError("invalid_hidden", "Session visibility must be a boolean.", field="hidden")
        with self.transaction():
            row = self.connection.execute("SELECT * FROM sessions WHERE id=? AND modality=?", (session_id, modality)).fetchone()
            if row is None: raise GenerationError("not_found", "The session was not found.", status=404)
            self.connection.execute("UPDATE sessions SET title=?,hidden=?,updated_at=? WHERE id=?",
                                    (changes.get("title", row["title"]), changes.get("hidden", row["hidden"]), self._now(), session_id))
            return self._session(self.connection.execute("SELECT * FROM sessions WHERE id=?", (session_id,)).fetchone())

    @staticmethod
    def _cursor(cursor: str | None):
        if cursor is None: return None
        try:
            value = json.loads(base64.urlsafe_b64decode(cursor.encode()))
            if not isinstance(value, list) or len(value) != 2 or not isinstance(value[0], (int, float)) or not isinstance(value[1], str): raise ValueError()
            return value
        except (ValueError, TypeError, UnicodeError):
            raise GenerationError("invalid_cursor", "The pagination cursor is invalid.", field="cursor") from None

    def _page(self, table: str, modality: str, cursor: str | None, limit: int, *, session_id=None, include_hidden=False):
        limit = max(1, min(limit, 100)); args: list = [modality]
        predicate = "modality=?"
        if table == "sessions" and not include_hidden: predicate += " AND hidden=0"
        if session_id and table == "jobs": predicate += " AND session_id=?"; args.append(session_id)
        position = self._cursor(cursor)
        if position:
            predicate += " AND (created_at<? OR (created_at=? AND id<?))"
            args.extend([position[0], position[0], position[1]])
        args.append(limit + 1)
        rows = self.connection.execute(f"SELECT * FROM {table} WHERE {predicate} ORDER BY created_at DESC,id DESC LIMIT ?", args).fetchall()
        next_cursor = None
        if len(rows) > limit:
            rows = rows[:limit]
            next_cursor = base64.urlsafe_b64encode(encode([rows[-1]["created_at"], rows[-1]["id"]]).encode()).decode()
        return rows, next_cursor

    def list_sessions(self, modality: str, cursor=None, limit=50, include_hidden=False) -> dict:
        with self.lock:
            rows, after = self._page("sessions", modality, cursor, limit, include_hidden=include_hidden)
            return {"items": [self._session(r) for r in rows], "next_cursor": after}

    def list_jobs(self, modality: str, cursor=None, limit=50, session_id=None) -> dict:
        with self.lock:
            rows, after = self._page("jobs", modality, cursor, limit, session_id=session_id)
            return {"items": [json.loads(r["data"]) for r in rows], "next_cursor": after}

    def get_job(self, job_id: str, modality: str | None = None) -> dict:
        with self.lock:
            row = self.connection.execute("SELECT data FROM jobs WHERE id=?", (job_id,)).fetchone()
            if row is None: raise GenerationError("not_found", "The generation was not found.", status=404)
            job = json.loads(row[0])
            if modality and job["modality"] != modality: raise GenerationError("not_found", "The generation was not found.", status=404)
            return job

    def idempotent_job(self, modality: str, key: str) -> dict | None:
        with self.lock:
            row = self.connection.execute("SELECT job_id FROM idempotency WHERE modality=? AND key=?", (modality, key)).fetchone()
            if row:
                try: return self.get_job(row[0], modality)
                except GenerationError: raise GenerationError("retained_idempotency", "This request identity belongs to a removed generation; choose a new key for a new request.", status=409) from None
            return None

    def submit(self, modality: str, request: dict, profile: dict, key: str, *, input_records=(), configuration_identity=None) -> dict:
        if modality not in {"music", "video"}: raise GenerationError("invalid_modality", "Unknown generation type.")
        if not isinstance(key, str) or not key.strip() or len(key) > 200:
            raise GenerationError("missing_idempotency_key", "Supply an Idempotency-Key for this generation.", field="Idempotency-Key")
        digest = fingerprint(request)
        with self.transaction():
            old = self.connection.execute("SELECT * FROM idempotency WHERE modality=? AND key=?", (modality, key)).fetchone()
            if old:
                if old["request_hash"] != digest: raise GenerationError("idempotency_conflict", "This request identity was already used with different parameters.", status=409)
                return self.get_job(old["job_id"], modality)
            queued = self.connection.execute("SELECT modality,count(*) FROM jobs WHERE state IN ('queued','recovery_hold') GROUP BY modality").fetchall()
            counts = {r[0]: r[1] for r in queued}
            if sum(counts.values()) >= 8 or (modality == "video" and counts.get("video", 0) >= 4):
                raise GenerationError("queue_full", "The generation queue is full. Wait for a job to finish.", retryable=True, status=429)
            sid = request.get("session_id")
            if sid:
                if self.connection.execute("SELECT id FROM sessions WHERE id=? AND modality=?", (sid, modality)).fetchone() is None:
                    raise GenerationError("session_not_found", "The selected session does not belong to this library.", field="session_id", status=404)
            else: sid = self._create_session(modality, request.get("prompt", "Untitled")[:60])["id"]
            now, jid = self._now(), identifier()
            job = {"job_id": jid, "store_id": self.store_id, "session_id": sid, "attempt_id": None,
                   "modality": modality, "state": "queued", "stage": "queued", "progress": None,
                   "created_at": now, "updated_at": now, "request": request, "profile": profile,
                   "effective_parameters": None, "asset_id": None, "error": None,
                   "provider_operation": None, "dispatch_intent": False, "provider_outcome": "not_started",
                   "local_observation": "observing", "remote_reservation": "none", "revision": 1,
                   "configuration_identity": configuration_identity, "cancel_requested": False}
            self.connection.execute("INSERT INTO jobs VALUES(?,?,?,?,?,?,?,?)", (jid, modality, sid, now, now, "queued", None, encode(job)))
            self.connection.execute("INSERT INTO idempotency VALUES(?,?,?,?,NULL)", (modality, key, digest, jid))
            for item in input_records:
                if self.connection.execute("SELECT id FROM inputs WHERE id=?", (item["input_id"],)).fetchone() is None:
                    raise GenerationError("input_not_found", "A reference image is unavailable.", field="inputs", status=404)
                self.connection.execute("INSERT OR IGNORE INTO input_usages VALUES(?,?,?)", (item["input_id"], jid, encode(item.get("transform", {}))))
            self._event(job, "accepted")
            return job

    def _event(self, job: dict, event_type: str) -> None:
        # Immutable large request/profile fields are stored once, not 1,000 times.
        value = {k: v for k, v in job.items() if k not in {"request", "profile", "configuration_identity"}}
        self.connection.execute("INSERT INTO events(job_id,type,data,created_at) VALUES(?,?,?,?)", (job["job_id"], event_type, encode(value), self._now()))
        self.connection.execute("DELETE FROM events WHERE job_id=? AND id NOT IN (SELECT id FROM events WHERE job_id=? ORDER BY id DESC LIMIT 1000)", (job["job_id"], job["job_id"]))

    def _save(self, job: dict, event_type="state") -> dict:
        job["updated_at"] = self._now(); job["revision"] += 1
        self.connection.execute("UPDATE jobs SET updated_at=?,state=?,attempt_id=?,data=? WHERE id=?", (job["updated_at"], job["state"], job["attempt_id"], encode(job), job["job_id"]))
        self._event(job, event_type)
        return job

    def begin_attempt(self, job_id: str) -> dict:
        with self.transaction():
            job = self.get_job(job_id)
            if job["state"] != "queued": raise GenerationError("invalid_state", "Only a queued generation can start.", status=409)
            if job["profile"]["deployment"] != "local":
                rows = self.connection.execute("SELECT data FROM jobs WHERE modality=?", (job["modality"],)).fetchall()
                if any(json.loads(r[0])["remote_reservation"] == "reserved" for r in rows):
                    raise GenerationError("remote_capacity_reserved", "A previous external generation still reserves capacity.", retryable=True, status=429)
                job["remote_reservation"] = "reserved"
            job.update(state="preparing", stage="preparing", attempt_id=identifier())
            return self._save(job)

    def update_attempt(self, job_id: str, attempt_id: str, **changes) -> bool:
        with self.transaction():
            job = self.get_job(job_id)
            if job["attempt_id"] != attempt_id or job["state"] in TERMINAL: return False
            target = changes.get("state", job["state"])
            if job["cancel_requested"] and target not in {"cancel_requested", "cancelled", "submission_unknown", "retrieval_pending"}: return False
            if target != job["state"] and target not in TRANSITIONS.get(job["state"], set()): return False
            job.update(changes)
            self._save(job, "progress" if set(changes) <= {"stage", "progress"} else "state")
            return True

    def dispatch(self, job_id: str, attempt_id: str) -> None:
        with self.transaction():
            job = self.get_job(job_id)
            if job["attempt_id"] != attempt_id or job["cancel_requested"] or job["state"] not in {"preparing", "running"}:
                raise GenerationError("invalid_attempt", "This generation attempt is no longer active.", status=409)
            if not job["dispatch_intent"]:
                job.update(dispatch_intent=True, state="running", stage="generating", provider_outcome="unknown")
                self._save(job)

    def record_operation(self, job_id: str, attempt_id: str, operation: Mapping) -> bool:
        with self.transaction():
            job = self.get_job(job_id)
            if job["attempt_id"] != attempt_id or job["state"] in TERMINAL: return False
            # Cancellation during POST must not lose a newly received provider ID.
            job["provider_operation"] = dict(operation)
            outcome=operation.get('provider_outcome')
            if outcome in {'pending','running','completed','succeeded','failed','cancelled','unknown'}:job['provider_outcome']=outcome
            if outcome in {'completed','succeeded','failed','cancelled'}:job['remote_reservation']='released'
            self._save(job, "provider_operation")
            return True

    def cancel(self, job_id: str) -> dict:
        with self.transaction():
            job = self.get_job(job_id)
            if job["state"] in TERMINAL or job["state"] == "cancel_requested": return job
            job["cancel_requested"] = True
            job["local_observation"] = "cancel_requested"
            job["state"] = "cancelled" if job["state"] in {"queued", "recovery_hold"} else "cancel_requested"
            job["stage"] = job["state"]
            return self._save(job)

    def finish_cancel(self, job_id: str, attempt_id: str, *, confirmed: bool, outcome="unknown") -> dict:
        with self.transaction():
            job = self.get_job(job_id)
            if job["attempt_id"] != attempt_id or job["state"] in TERMINAL: return job
            job.update(state="cancelled", stage="cancelled", local_observation="stopped", provider_outcome=outcome)
            if confirmed: job["remote_reservation"] = "released"
            return self._save(job)

    def resume(self, job_id: str) -> dict:
        with self.transaction():
            job = self.get_job(job_id)
            if job["state"] == "queued" and not job["dispatch_intent"] and not job["cancel_requested"]: return job
            if job["state"] != "recovery_hold" or job["dispatch_intent"] or job["cancel_requested"]:
                raise GenerationError("not_resumable", "Only a never-dispatched recovery-held generation can resume.", status=409)
            job.update(state="queued", stage="queued")
            return self._save(job)

    def release_reservation(self, job_id: str, acknowledgment: bool) -> dict:
        if acknowledgment is not True:
            raise GenerationError("acknowledgment_required", "Acknowledge that the provider may still execute and charge for this generation.", field="acknowledge_possible_execution_and_charges")
        with self.transaction():
            job = self.get_job(job_id)
            if job["profile"]["deployment"] == "local": raise GenerationError("not_remote", "This generation has no external reservation.", status=409)
            if job["remote_reservation"] == "released": return job
            if job["state"] not in {"submission_unknown", "cancelled", "cancel_requested"}:
                raise GenerationError("reservation_not_releasable", "Only unresolved external work can release its reservation.", status=409)
            job["remote_reservation"] = "released"
            return self._save(job, "reservation_released")

    def recover(self) -> None:
        with self.transaction():
            rows = self.connection.execute("SELECT id FROM jobs").fetchall()
            for row in rows:
                job = self.get_job(row[0])
                if job["state"] in TERMINAL: continue
                if self.connection.execute("SELECT 1 FROM publications WHERE job_id=?", (job["job_id"],)).fetchone(): continue
                if job["cancel_requested"]:
                    job.update(state="cancelled", stage="cancelled", local_observation="stopped")
                    if job["profile"]["deployment"] == "local" or not job["dispatch_intent"]: job["remote_reservation"] = "released"
                elif not job["dispatch_intent"]:
                    job.update(state="recovery_hold", stage="recovery_hold", attempt_id=None, remote_reservation="none")
                elif job["profile"]["deployment"] == "local":
                    job.update(state="interrupted", stage="interrupted", provider_outcome="interrupted")
                elif job["provider_operation"] and job['profile'].get('capabilities',{}).get('retrieval_supported',False):
                    job.update(state="retrieval_pending", stage="reconciling")
                else:
                    job.update(state="submission_unknown", stage="submission_unknown")
                self._save(job, "recovery")

    def queued_jobs(self) -> list[dict]:
        with self.lock:
            return [json.loads(r[0]) for r in self.connection.execute("SELECT data FROM jobs WHERE state='queued' ORDER BY created_at,id").fetchall()]

    def events(self, job_id: str, after: int = 0) -> list[dict]:
        with self.lock:
            job = self.get_job(job_id)
            oldest = self.connection.execute("SELECT min(id),max(id) FROM events WHERE job_id=?", (job_id,)).fetchone()
            if after and oldest[0] and after < oldest[0]: return [{"id": oldest[1], "type": "snapshot", "job": job}]
            rows = self.connection.execute("SELECT id,type,data FROM events WHERE job_id=? AND id>? ORDER BY id LIMIT 1000", (job_id, after)).fetchall()
            return [{"id": r[0], "type": r[1], "job": {**job, **json.loads(r[2])}} for r in rows]

    def asset(self, asset_id: str) -> dict:
        with self.lock:
            row = self.connection.execute("SELECT * FROM assets WHERE id=?", (asset_id,)).fetchone()
            if row is None: raise GenerationError("asset_not_found", "The generated asset was not found.", status=404)
            value = dict(row)
            value["asset_id"] = value.pop("id"); value["store_id"] = self.store_id
            value["metadata"] = json.loads(value["metadata"]); value["trashed"] = bool(value["trashed"])
            return value

    def usages(self, asset_id: str) -> dict:
        with self.lock:
            self.asset(asset_id)
            rows = self.connection.execute("SELECT * FROM asset_references WHERE asset_id=? AND state!='released' ORDER BY id", (asset_id,)).fetchall()
            return {"items": [{**dict(r), "owner": json.loads(r["owner"])} for r in rows]}

    def put_reference(self, asset_id: str, reference_id: str, phase: str, expected_revision: int, owner: Mapping) -> dict:
        if phase not in {"reserve", "finalize"}: raise GenerationError("invalid_reference_phase", "Use reserve or finalize.", field="phase")
        with self.transaction():
            asset = self.asset(asset_id)
            if asset["trashed"]: raise GenerationError("asset_trashed", "Restore this asset before attaching it.", status=409)
            old = self.connection.execute("SELECT * FROM asset_references WHERE asset_id=? AND id=?", (asset_id, reference_id)).fetchone()
            state = "reserved" if phase == "reserve" else "live"
            if old:
                if old["state"] == "released": raise GenerationError("reference_released", "This reference was released. Use a new identity to attach again.", status=409)
                if old["state"] == state and old["owner"] == encode(owner): return {**dict(old), "owner": dict(owner)}
                if old["revision"] != expected_revision or old["owner"] != encode(owner): raise GenerationError("reference_conflict", "The asset reference changed. Refresh before retrying.", status=409)
                if state == "reserved" and old["state"] == "live": raise GenerationError("reference_conflict", "An active reference cannot become a reservation.", status=409)
            elif expected_revision != 0 or phase != "reserve":
                raise GenerationError("reference_conflict", "Reserve a new reference before finalizing it.", status=409)
            revision = old["revision"] + 1 if old else 1
            self.connection.execute("INSERT OR REPLACE INTO asset_references VALUES(?,?,?,?,?,?)", (asset_id, reference_id, state, revision, encode(owner), self._now()))
            return {"asset_id": asset_id, "id": reference_id, "state": state, "revision": revision, "owner": dict(owner)}

    def delete_reference(self, asset_id: str, reference_id: str, expected_revision: int) -> dict:
        with self.transaction():
            self.asset(asset_id)
            old = self.connection.execute("SELECT * FROM asset_references WHERE asset_id=? AND id=?", (asset_id, reference_id)).fetchone()
            if old is None: raise GenerationError("reference_not_found", "The reference was not found.", status=404)
            if old["state"] == "released": return {**dict(old), "owner": json.loads(old["owner"])}
            if old["revision"] != expected_revision: raise GenerationError("reference_conflict", "The reference changed. Refresh before unlinking it.", status=409)
            self.connection.execute("UPDATE asset_references SET state='released',revision=revision+1,updated_at=? WHERE asset_id=? AND id=?", (self._now(), asset_id, reference_id))
            return {**dict(old), "state": "released", "revision": old["revision"] + 1, "owner": json.loads(old["owner"])}
