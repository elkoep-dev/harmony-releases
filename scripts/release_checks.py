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


def check_build_record(log, release_id, expected_hash):
    records = re.findall(r'^(?:\d{4}-\d{2}-\d{2}T[\d:.]+Z )?HARMONY_RELEASE_HANDOFF=(\{[^\r\n]+\})\r?$',
                         log, re.MULTILINE)
    require(len(records) == 1, "missing or ambiguous build handoff record")
    record = json.loads(records[0])
    require(record == {"release_id": release_id, "sha256": expected_hash}, "handoff does not match the build job")


def check_handoff(release, repo, run_id, attempt, release_id, commit, version, expected_hash):
    require(release.get("id") == release_id and release.get("draft") is False
            and release.get("prerelease") is True, "invalid private handoff release")
    require(release.get("tag_name") == f"handoff-build-{run_id}-{attempt}"
            and release.get("target_commitish") == commit, "handoff tag/commit mismatch")
    body = release.get("body") or ""
    require(hashlib.sha256(body.encode()).hexdigest() == expected_hash, "handoff metadata changed")
    index = json.loads(body)
    context = {"schema": 1, "kind": "build", "repository": repo, "run_id": run_id,
               "run_attempt": attempt, "commit": commit, "version": version}
    require(all(type(index.get(k)) is type(v) and index[k] == v for k, v in context.items()),
            "handoff source/run mismatch")
    files = index.get("files")
    names = {f"harmony-{version}.tar.gz", f"harmony-{version}.manifest.json", "install.sh", "notes.md"}
    require(isinstance(files, dict) and set(files) == names, "unexpected handoff files")
    assets = release.get("assets") or []
    require(len(assets) == 4 and {a.get("name") for a in assets} == names, "handoff assets changed")
    for asset in assets:
        record = files[asset["name"]]
        require(type(record.get("id")) is int and record["id"] > 0 and record["id"] == asset.get("id"),
                "handoff asset replaced")
        require(type(record.get("size")) is int and 0 < record["size"] < 2 * 1024 ** 3
                and record["size"] == asset.get("size") and asset.get("state") == "uploaded", "invalid asset size/state")
        require(re.fullmatch(r"[0-9a-f]{64}", record.get("sha256", "")), "invalid asset checksum")
        require(type(record.get("mode")) is int and 0 < record["mode"] <= 0o777, "invalid asset permissions")
    require(len({record["id"] for record in files.values()}) == 4, "duplicate asset ID")
    return files


def all_jobs(path, fetch=None):
    if fetch is None:
        fetch = api
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
    values = [os.environ[k] for k in ("SOURCE_RUN_ID", "SOURCE_RUN_ATTEMPT", "HANDOFF_RELEASE_ID")]
    require(all(re.fullmatch(r"[1-9][0-9]*", v) for v in values), "invalid run/attempt/release ID")
    run_id, attempt, release_id = map(int, values)
    expected_hash = os.environ["HANDOFF_SHA256"]
    require(re.fullmatch(r"[0-9a-f]{64}", expected_hash), "invalid handoff checksum")
    path = f"repos/{repo}/actions/runs/{run_id}/attempts/{attempt}"
    deadline = time.monotonic() + 1200
    while True:
        run = api(path)
        check_run(run, repo, commit, attempt)
        if run.get("status") == "completed":
            break
        require(time.monotonic() < deadline, "source attempt did not finish within 20 minutes")
        time.sleep(10)
    jobs = all_jobs(path + "/jobs")
    check_jobs(jobs)
    builds = [job for job in jobs if job.get("name") == "build"]
    require(len(builds) == 1, "missing or ambiguous source build job")
    # Dispatch inputs and release metadata are mutable. Bind both to the independent,
    # GitHub-hosted log of the successful canonical build job before trusting assets.
    log = subprocess.check_output(["gh", "api", f"repos/{repo}/actions/jobs/{builds[0]['id']}/logs"], text=True)
    check_build_record(log, release_id, expected_hash)
    require(api(f"repos/{repo}").get("private") is True, "handoff repository must be private")
    release = api(f"repos/{repo}/releases/{release_id}")
    files = check_handoff(release, repo, run_id, attempt, release_id, commit, version, expected_hash)
    require(files[f"harmony-{version}.tar.gz"]["sha256"] == os.environ["EXPECTED_SHA256"], "package input mismatch")
    Path("authorized-handoff.json").write_text(json.dumps(files))
    print(f"Authorized {repo}@{commit}, run {run_id}, attempt {attempt}, handoff {release_id}")


def download():
    repo = os.environ["SOURCE_REPO"]
    files = json.loads(Path("authorized-handoff.json").read_text())
    directory = Path("dist")
    directory.mkdir(exist_ok=True)
    for name, record in files.items():
        target = directory / name
        with target.open("xb") as output:
            subprocess.run(["gh", "api", f"repos/{repo}/releases/assets/{record['id']}",
                            "-H", "Accept: application/octet-stream"], stdout=output, check=True)
        require(target.stat().st_size == record["size"], "download size mismatch")
        with target.open("rb") as source:
            require(hashlib.file_digest(source, "sha256").hexdigest() == record["sha256"], "download checksum mismatch")
        target.chmod(record["mode"])


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
        {"provenance": provenance, "download": download, "manifest": manifest, "operator": operator}[sys.argv[1]]()
    except (Rejected, KeyError, ValueError) as error:
        sys.exit(f"Release rejected: {error}")
