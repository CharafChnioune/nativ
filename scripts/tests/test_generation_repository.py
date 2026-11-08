import concurrent.futures
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "PythonDistribution/Overlay"))
from nativ_generation.contracts import GenerationError
from nativ_generation.repository import GenerationRepository


class GenerationRepositoryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.repo = GenerationRepository(Path(self.directory.name))
        self.profile = {"id": "fixture", "profile_revision": "1", "deployment": "local"}

    def tearDown(self):
        self.repo.close(); self.directory.cleanup()

    def submit(self, key="same", prompt="test"):
        return self.repo.submit("music", {"model": "fixture", "prompt": prompt}, self.profile, key)

    def test_concurrent_duplicate_reserves_one_job_and_session(self):
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            jobs = list(pool.map(lambda _: self.submit(), range(20)))
        self.assertEqual(len({j["job_id"] for j in jobs}), 1)
        self.assertEqual(len(self.repo.list_jobs("music")["items"]), 1)
        self.assertEqual(len(self.repo.list_sessions("music")["items"]), 1)
        with self.assertRaises(GenerationError) as error:
            self.submit(prompt="different")
        self.assertEqual(error.exception.status, 409)

    def test_second_scheduler_is_rejected_and_store_identity_survives_restart(self):
        with self.assertRaises(GenerationError) as error:
            GenerationRepository(Path(self.directory.name))
        self.assertEqual(error.exception.code, "store_in_use")
        identity = self.repo.store_id
        self.repo.close(); self.repo = GenerationRepository(Path(self.directory.name))
        self.assertEqual(self.repo.store_id, identity)

    def test_restart_holds_undispatched_but_preserves_cancelled_and_unknown(self):
        queued = self.submit("queued")
        cancelled = self.submit("cancelled")
        self.repo.cancel(cancelled["job_id"])
        remote = self.repo.submit("video", {"model": "cloud", "prompt": "x"},
                                  {"id": "cloud", "deployment": "hosted", "profile_revision": "1"}, "remote")
        active = self.repo.begin_attempt(remote["job_id"])
        self.repo.dispatch(active["job_id"], active["attempt_id"])
        self.repo.close(); self.repo = GenerationRepository(Path(self.directory.name)); self.repo.recover()
        self.assertEqual(self.repo.get_job(queued["job_id"])["state"], "recovery_hold")
        self.assertEqual(self.repo.get_job(cancelled["job_id"])["state"], "cancelled")
        unknown = self.repo.get_job(remote["job_id"])
        self.assertEqual(unknown["state"], "submission_unknown")
        self.assertEqual(unknown["remote_reservation"], "reserved")

    def test_cancel_and_stale_attempt_cannot_resurrect_job(self):
        job = self.repo.begin_attempt(self.submit()["job_id"])
        self.repo.cancel(job["job_id"])
        self.assertFalse(self.repo.update_attempt(job["job_id"], "not-the-attempt", stage="running"))
        self.assertFalse(self.repo.update_attempt(job["job_id"], job["attempt_id"], state="running"))
        self.repo.finish_cancel(job["job_id"], job["attempt_id"], confirmed=True)
        self.assertEqual(self.repo.get_job(job["job_id"])["state"], "cancelled")

    def test_queue_limits_do_not_reject_idempotent_existing_request(self):
        first = self.submit("first")
        for i in range(7): self.submit(str(i))
        self.assertEqual(self.submit("first")["job_id"], first["job_id"])
        with self.assertRaises(GenerationError) as error: self.submit("overflow")
        self.assertEqual(error.exception.code, "queue_full")

    def test_resume_never_replays_dispatched_or_terminal_work(self):
        job = self.submit()
        self.repo.recover()
        self.assertEqual(self.repo.resume(job["job_id"])["job_id"], job["job_id"])
        active = self.repo.begin_attempt(job["job_id"])
        self.repo.dispatch(active["job_id"], active["attempt_id"])
        with self.assertRaises(GenerationError): self.repo.resume(job["job_id"])

    def test_reference_tombstone_rejects_late_finalize(self):
        # A fake asset row isolates the cross-client reference state machine.
        self.repo.connection.execute("INSERT INTO assets VALUES(?,?,?,?,?,?,?,?,?,?,?,?)",
            ("asset", "job", "music", "assets/asset/a.wav", "a.wav", "audio/wav", 1, "a"*64, 0, 0, "{}", 1))
        reserved = self.repo.put_reference("asset", "chat-reference", "reserve", 0, {"kind": "chat"})
        released = self.repo.delete_reference("asset", "chat-reference", reserved["revision"])
        self.assertEqual(released["state"], "released")
        with self.assertRaises(GenerationError): self.repo.put_reference("asset", "chat-reference", "finalize", reserved["revision"], {"kind": "chat"})
        self.assertEqual(self.repo.usages("asset")["items"], [])


if __name__ == "__main__": unittest.main()
