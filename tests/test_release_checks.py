import copy
import importlib.util
import hashlib
import tempfile
import json
import os
from unittest.mock import patch
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




class HandoffTests(unittest.TestCase):
    def setUp(self):
        self.files = {name: {"id": i, "size": 20, "sha256": "b" * 64, "mode": 0o644}
                      for i, name in enumerate(("harmony-1.2.3.tar.gz", "harmony-1.2.3.manifest.json",
                                               "install.sh", "notes.md"), 1)}
        self.index = {"schema": 1, "kind": "build", "repository": "owner/source", "run_id": 8,
                      "run_attempt": 2, "commit": "a" * 40, "version": "1.2.3", "files": self.files}
        self.release = {"id": 9, "draft": False, "prerelease": True, "tag_name": "handoff-build-8-2",
                        "target_commitish": "a" * 40,
                        "assets": [{"name": name, "id": item["id"], "size": item["size"], "state": "uploaded"}
                                   for name, item in self.files.items()]}
        self.seal()

    def seal(self):
        self.release["body"] = json.dumps(self.index)
        self.sha = hashlib.sha256(self.release["body"].encode()).hexdigest()

    def check(self):
        return checks.check_handoff(self.release, "owner/source", 8, 2, 9, "a" * 40, "1.2.3", self.sha)

    def test_handoff_and_authenticated_build_log(self):
        self.assertEqual(self.check(), self.files)
        record = json.dumps({"release_id": 9, "sha256": self.sha})
        checks.check_build_record("2026-10-19T12:00:00.1234567Z HARMONY_RELEASE_HANDOFF=" + record + "\n", 9, self.sha)
        for log in ("", "HARMONY_RELEASE_HANDOFF=" + record + "\nHARMONY_RELEASE_HANDOFF=" + record,
                    "HARMONY_RELEASE_HANDOFF=" + json.dumps({"release_id": 10, "sha256": self.sha}),
                    "HARMONY_RELEASE_HANDOFF=" + json.dumps({"release_id": 9, "sha256": "f" * 64}),
                    "echo HARMONY_RELEASE_HANDOFF=" + record):
            with self.subTest(log=log), self.assertRaises(checks.Rejected):
                checks.check_build_record(log, 9, self.sha)

    def test_state_origin_attempt_and_commit_are_checked(self):
        for key, value in (("id", 10), ("draft", True), ("prerelease", False),
                           ("tag_name", "handoff-build-8-1"), ("target_commitish", "main"),
                           ("body", "{}")):
            with self.subTest(key=key), self.assertRaises(checks.Rejected):
                checks.check_handoff({**self.release, key: value}, "owner/source", 8, 2, 9,
                                     "a" * 40, "1.2.3", self.sha)
        for key, value in (("kind", "tests"), ("schema", True), ("repository", "other/source"),
                           ("run_id", 7), ("run_attempt", 1), ("commit", "f" * 40), ("version", "1.2.4")):
            with self.subTest(key=key), self.assertRaises(checks.Rejected):
                bad = {**self.index, key: value}
                self.release["body"] = json.dumps(bad)
                self.sha = hashlib.sha256(self.release["body"].encode()).hexdigest()
                self.check()
        self.index["files"]["../../install.sh"] = self.index["files"].pop("install.sh")
        self.seal()
        with self.assertRaises(checks.Rejected):
            self.check()

    def test_replacement_incomplete_upload_and_size_mismatch(self):
        for key, value in (("id", 99), ("state", "starter"), ("size", 21)):
            original = copy.deepcopy(self.release)
            self.release["assets"][0][key] = value
            with self.subTest(key=key), self.assertRaises(checks.Rejected):
                self.check()
            self.release = original
        self.release["assets"].append(self.release["assets"][0])
        with self.assertRaises(checks.Rejected):
            self.check()

    def test_provenance_reads_log_from_the_canonical_build_job(self):
        run = {"path": ".github/workflows/release.yml", "head_branch": "main", "event": "push",
               "head_repository": {"full_name": "owner/source"}, "head_sha": "a" * 40,
               "run_attempt": 2, "status": "completed", "conclusion": "success"}
        jobs = [{"id": 101, "name": "build", "status": "completed", "conclusion": "success"},
                {"id": 102, "name": "gate", "status": "completed", "conclusion": "success"}]
        env = {"SOURCE_REPO": "owner/source", "VERSION": "1.2.3", "SOURCE_SHA": "a" * 40,
               "SOURCE_RUN_ID": "8", "SOURCE_RUN_ATTEMPT": "2", "HANDOFF_RELEASE_ID": "9",
               "HANDOFF_SHA256": self.sha, "EXPECTED_SHA256": "b" * 64}
        def fetch(path):
            if path.endswith("/attempts/2"):
                return run
            if path.endswith("/jobs?per_page=100&page=1"):
                return {"jobs": jobs}
            if path == "repos/owner/source":
                return {"private": True}
            if path.endswith("/releases/9"):
                return self.release
            self.fail(path)
        record = "\x1b[32mbuild output\x1b[0m\nHARMONY_RELEASE_HANDOFF=" + json.dumps({"release_id": 9, "sha256": self.sha})
        previous = Path.cwd()
        with tempfile.TemporaryDirectory() as directory, patch.dict(os.environ, env), \
                patch.object(checks, "api", side_effect=fetch), \
                patch.object(checks.subprocess, "check_output", return_value=record) as log:
            os.chdir(directory)
            try:
                checks.provenance()
                self.assertEqual(json.loads(Path("authorized-handoff.json").read_text()), self.files)
                log.assert_called_once_with(["gh", "api", "--allow-escape-sequences",
                                             "repos/owner/source/actions/jobs/101/logs"], text=True)
                jobs[0]["conclusion"] = "failure"
                with self.assertRaises(checks.Rejected):
                    checks.provenance()
            finally:
                os.chdir(previous)

    def test_download_preserves_binary_bytes_and_rejects_tampering(self):
        payload = b"\x1b[31m\x00\xffexact package bytes\x1b[0m"
        name = "harmony-1.2.3.tar.gz"
        files = {name: {"id": 1, "size": len(payload), "mode": 0o644,
                        "sha256": hashlib.sha256(payload).hexdigest()}}
        for body in (payload, payload.replace(b"exact", b"other")):
            with self.subTest(tampered=body != payload), tempfile.TemporaryDirectory() as directory:
                previous = Path.cwd()
                os.chdir(directory)
                try:
                    Path("authorized-handoff.json").write_text(json.dumps(files))
                    def download(command, *, stdout, check):
                        self.assertEqual(command, ["gh", "api", "--allow-escape-sequences",
                                                   "repos/owner/source/releases/assets/1",
                                                   "-H", "Accept: application/octet-stream"])
                        self.assertTrue(check)
                        stdout.write(body)
                    with patch.dict(os.environ, {"SOURCE_REPO": "owner/source"}), \
                            patch.object(checks.subprocess, "run", side_effect=download):
                        if body == payload:
                            checks.download()
                            self.assertEqual((Path("dist") / name).read_bytes(), payload)
                        else:
                            with self.assertRaises(checks.Rejected):
                                checks.download()
                finally:
                    os.chdir(previous)


if __name__ == "__main__":
    unittest.main()
