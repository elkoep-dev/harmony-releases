import copy
import importlib.util
import hashlib
import tempfile
import unittest
from pathlib import Path

spec = importlib.util.spec_from_file_location("checks", Path(__file__).parents[1] / "scripts/release_checks.py")
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)


class AuthorizationTests(unittest.TestCase):
    def setUp(self):
        self.run = {"path": ".github/workflows/release.yml", "head_branch": "main", "event": "push",
                    "head_repository": {"full_name": "owner/source"}, "head_sha": "a" * 40,
                    "run_attempt": 2, "status": "completed", "conclusion": "success"}

    def test_authorized_run(self):
        checks.check_run(self.run, "owner/source", "a" * 40, 2)

    def test_wrong_origin_or_attempt(self):
        for key, value in [("path", ".github/workflows/ci.yml"), ("head_branch", "feature"),
                           ("event", "pull_request"), ("head_repository", {"full_name": "fork/source"}),
                           ("head_sha", "b" * 40), ("run_attempt", 1), ("conclusion", "failure")]:
            with self.subTest(key=key), self.assertRaises(checks.Rejected):
                checks.check_run({**self.run, key: value}, "owner/source", "a" * 40, 2)

    def test_artifact_attempt_binding(self):
        artifact = {"id": 9, "expired": False, "name": "release-1.2.3-8-2",
                    "workflow_run": {"id": 8, "head_sha": "a" * 40, "head_branch": "main"}}
        checks.check_artifact(artifact, "owner/source", 8, 2, 9, "a" * 40, "1.2.3")
        for key, value in [("id", 10), ("expired", True), ("name", "release-1.2.3-8-1"),
                           ("workflow_run", {"id": 7, "head_sha": "a" * 40, "head_branch": "main"})]:
            with self.subTest(key=key), self.assertRaises(checks.Rejected):
                checks.check_artifact({**artifact, key: value}, "owner/source", 8, 2, 9, "a" * 40, "1.2.3")

    def test_human_dispatch_and_rerun(self):
        event = {"sender": {"type": "User"}}
        checks.check_operator(event, "operator", "operator", "operator", "refs/heads/main")
        for sender, actor, rerun, ref in [("Bot", "app[bot]", "operator", "refs/heads/main"),
                                         ("User", "other", "operator", "refs/heads/main"),
                                         ("User", "operator", "other", "refs/heads/main"),
                                         ("User", "operator", "operator", "refs/heads/feature")]:
            with self.subTest(actor=actor, rerun=rerun, ref=ref), self.assertRaises(checks.Rejected):
                checks.check_operator({"sender": {"type": sender}}, actor, rerun, "operator", ref)

    def test_only_candidates_promote(self):
        checks.check_candidate({"isPrerelease": True, "name": "Harmony 1.2.3 (candidate)"})
        for release in [{"isPrerelease": True, "name": "Harmony 1.2.3 (withdrawn)"},
                        {"isPrerelease": False, "name": "Harmony 1.2.3"},
                        {"isPrerelease": True, "isDraft": True, "name": "Harmony 1.2.3 (candidate)"}]:
            with self.assertRaises(checks.Rejected):
                checks.check_candidate(release)

    def test_skipped_gate_and_missing_gate(self):
        jobs = [{"name": n, "status": "completed", "conclusion": "success"}
                for n in ("check", "build", "gate", "publish", "upgrade-tests / fresh")]
        checks.check_jobs(jobs)
        for bad in ([job for job in jobs if job["name"] != "gate"],
                    [*jobs, {"name": "extra", "status": "completed", "conclusion": "skipped"}],
                    [*jobs[:-1], {"name": "upgrade-tests / fresh", "status": "completed", "conclusion": "failure"}]):
            with self.assertRaises(checks.Rejected):
                checks.check_jobs(copy.deepcopy(bad))

    def test_manifest_binds_commit_version_and_exact_bytes(self):
        with tempfile.TemporaryDirectory() as directory:
            package = Path(directory) / 'harmony-1.2.3.tar.gz'
            package.write_bytes(b'exact artifact')
            digest = hashlib.sha256(package.read_bytes()).hexdigest()
            manifest = {'schema': 1, 'product': 'harmony', 'version': '1.2.3', 'commit': 'a' * 40,
                        'min_updater_protocol': 1,
                        'artifact': {'name': package.name, 'size': package.stat().st_size, 'sha256': digest}}
            checks.check_manifest(manifest, package, '1.2.3', 'a' * 40, digest)
            for key, value in [('schema', True), ('product', 'other'), ('version', '1.2.4'),
                               ('commit', 'b' * 40), ('min_updater_protocol', None)]:
                with self.subTest(key=key), self.assertRaises(checks.Rejected):
                    checks.check_manifest({**manifest, key: value}, package, '1.2.3', 'a' * 40, digest)
            package.write_bytes(b'modified bytes')
            with self.assertRaises(checks.Rejected):
                checks.check_manifest(manifest, package, '1.2.3', 'a' * 40, digest)


if __name__ == "__main__":
    unittest.main()
