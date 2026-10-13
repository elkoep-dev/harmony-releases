#!/usr/bin/env python3
"""Fail-closed authorization checks used by the public signing workflows."""

import hashlib
import json
import os
import re
import subprocess
import time
from pathlib import Path


class Rejected(RuntimeError):
    pass


def require(condition, message):
    if not condition:
        raise Rejected(message)


def api(path):
    return json.loads(subprocess.check_output(["gh", "api", path], text=True))


def check_run(run, repo, commit, attempt):
    require(run.get("path") == ".github/workflows/release.yml", "unexpected workflow")
    require(run.get("head_branch") == "main", "source branch must be main")
    require(run.get("event") in ("push", "workflow_dispatch"), "unexpected source event")
    require((run.get("head_repository") or {}).get("full_name") == repo, "unexpected source repository")
    require(run.get("head_sha") == commit, "source commit mismatch")
    require(run.get("run_attempt") == attempt, "source attempt mismatch")
    if run.get("status") == "completed":
        require(run.get("conclusion") == "success", "source run did not succeed")


def check_jobs(jobs):
    # The source run's "gate" job checks that the complete release test set ran and passed.
    require(any(j.get("name") == "gate" for j in jobs), "the source run has no release gate")
    require(all(j.get("status") == "completed" and j.get("conclusion") == "success" for j in jobs),
            "a source job failed, was cancelled or was skipped")


def check_artifact(artifact, repo, run_id, attempt, artifact_id, commit, version):
    require(artifact.get("id") == artifact_id and not artifact.get("expired"), "invalid artifact ID/expiry")
    require(artifact.get("name") == f"release-{version}-{run_id}-{attempt}", "artifact attempt/name mismatch")
    run = artifact.get("workflow_run") or {}
    require(run.get("id") == run_id and run.get("head_sha") == commit and run.get("head_branch") == "main",
            "artifact source mismatch")
    # The API route fixes the source repo. There is no run_attempt field in an artifact.
    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo), "invalid repository")


def all_jobs(path, fetch=api):
    jobs = []
    page = 1
    while True:
        result = fetch(f"{path}?per_page=100&page={page}")
        batch = result["jobs"]
        jobs.extend(batch)
        if len(batch) < 100:
            return jobs
        page += 1


def provenance():
    repo = os.environ["SOURCE_REPO"]
    version = os.environ["VERSION"]
    commit = os.environ["SOURCE_SHA"]
    require(re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo), "invalid repository")
    require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version), "invalid version")
    require(re.fullmatch(r"[0-9a-f]{40}", commit), "invalid full commit SHA")
    values = [os.environ[k] for k in ("SOURCE_RUN_ID", "SOURCE_RUN_ATTEMPT", "SOURCE_ARTIFACT_ID")]
    require(all(re.fullmatch(r"[1-9][0-9]*", v) for v in values), "invalid run/attempt/artifact ID")
    run_id, attempt, artifact_id = map(int, values)
    path = f"repos/{repo}/actions/runs/{run_id}/attempts/{attempt}"
    deadline = time.monotonic() + 1200
    while True:
        run = api(path)
        check_run(run, repo, commit, attempt)
        if run.get("status") == "completed":
            break
        require(time.monotonic() < deadline, "source attempt did not finish within 20 minutes")
        time.sleep(10)
    check_jobs(all_jobs(path + "/jobs"))
    artifact = api(f"repos/{repo}/actions/artifacts/{artifact_id}")
    check_artifact(artifact, repo, run_id, attempt, artifact_id, commit, version)
    print(f"Authorized {repo}@{commit}, run {run_id}, attempt {attempt}, artifact {artifact_id}")


def check_manifest(manifest, package, version, commit, expected_hash):
    require(type(manifest.get("schema")) is int and manifest["schema"] == 1
            and manifest.get("product") == "harmony", "invalid manifest schema/product")
    require(manifest.get("version") == version and manifest.get("commit") == commit, "manifest version/commit mismatch")
    art = manifest.get("artifact") or {}
    require(art.get("name") == package.name == f"harmony-{version}.tar.gz", "artifact filename mismatch")
    require(type(art.get("size")) is int and art["size"] == package.stat().st_size, "artifact size mismatch")
    require(re.fullmatch(r"[0-9a-f]{64}", expected_hash or ""), "invalid expected checksum")
    with package.open("rb") as source:
        digest = hashlib.file_digest(source, "sha256").hexdigest()
    require(art.get("sha256") == digest == expected_hash, "artifact checksum mismatch")
    require(type(manifest.get("min_updater_protocol")) is int and manifest["min_updater_protocol"] >= 1,
            "missing updater compatibility contract")


def manifest():
    version = os.environ["VERSION"]
    path = Path("dist") / f"harmony-{version}.manifest.json"
    data = json.loads(path.read_text())
    check_manifest(data, path.with_name(f"harmony-{version}.tar.gz"), version,
                   os.environ["SOURCE_SHA"], os.environ["EXPECTED_SHA256"])
    print("Manifest and exact artifact authorized")


def check_operator(event, actor, triggering_actor, operators, ref):
    require(ref == "refs/heads/main", "workflow must run on main")
    require((event.get("sender") or {}).get("type") == "User", "only human operators may change release state")
    allowed = set(operators.replace(",", " ").split())
    require(bool(allowed) and actor in allowed and triggering_actor in allowed, "unauthorized initial/rerun operator")


def operator():
    check_operator(json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text()),
                   os.environ["GITHUB_ACTOR"], os.environ["TRIGGERING_ACTOR"],
                   os.environ.get("RELEASE_OPERATORS", ""), os.environ["GITHUB_REF"])


def check_candidate(release):
    require(not release.get("isDraft", release.get("draft", False)), "draft cannot be promoted")
    require(release.get("isPrerelease", release.get("prerelease")) is True, "release is already stable")
    require((release.get("name") or "").endswith("(candidate)"), "only a candidate can be promoted; withdrawal is terminal")


if __name__ == "__main__":
    import sys
    try:
        {"provenance": provenance, "manifest": manifest, "operator": operator}[sys.argv[1]]()
    except (Rejected, KeyError, ValueError) as error:
        sys.exit(f"Release rejected: {error}")
