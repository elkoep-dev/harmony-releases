# iNELS Harmony releases

Signed releases of [iNELS Harmony](https://github.com/elkoep-dev/harmony). Hotel
servers install and update from here with `harmony-update`.

## Install or upgrade a server

On the server, with the release's `install.sh` and its sha256 from the release
manager:

```sh
curl -fsSLO https://github.com/elkoep-dev/harmony-releases/releases/latest/download/install.sh
sha256sum install.sh
sudo bash install.sh --registration-token hrt_xxxxxxxxxxxx   # new server
sudo bash install.sh --upgrade                               # server on 1.0.x
```

Servers on 1.1 and newer update from their admin UI. The `install.sh` in this
repository's main branch is the 1.0 installer.

## Files of a release

| File | What it is |
|---|---|
| `harmony-X.Y.Z.tar.gz` | install and upgrade package |
| `harmony-X.Y.Z.manifest.json` | version, source commit, sha256 of the package |
| `harmony-X.Y.Z.manifest.json.sig` | signature of the manifest (`ssh-keygen -Y`, namespace `harmony-release`) |
| `install.sh` | installer with the trusted public keys |

Verify by hand:

```sh
ssh-keygen -Y verify -f allowed_signers -I harmony-release -n harmony-release \
  -s harmony-X.Y.Z.manifest.json.sig < harmony-X.Y.Z.manifest.json
sha256sum harmony-X.Y.Z.tar.gz   # must equal artifact.sha256 in the manifest
```

## Workflows

| Workflow | Started by | What it does |
|---|---|---|
| Publish candidate | the Release workflow of harmony | checks that the build comes from a successful release run on main, signs it and publishes it as a candidate (pre-release) |
| Promote release | a release operator, after testing on the lab | checks signature and checksum, makes the candidate the latest release |
| Withdraw release | a release operator | servers stop offering the release; servers running it keep it |

All run in the protected `production` environment (main only), which holds the
signing key. Published versions are never replaced. `allowed_signers` lists the
public keys servers trust: the main key and an offline backup key.

## Build transfer

The source workflow stores the package, manifest, installer and notes as temporary
release assets inside the private `harmony` repository. Each attempt has a unique
`handoff-build-RUN-ATTEMPT` prerelease. These files do not consume Actions Artifacts
storage, and do not become public until all release gates pass and this workflow
signs and publishes the candidate.

The publisher checks the canonical source workflow, main branch, full SHA, exact
attempt and every successful job. It reads the handoff ID and index checksum from
the successful source build job's GitHub log independently of dispatch inputs. It
then verifies the index, asset IDs, sizes and SHA-256 checksums of all four files,
and the manifest's package identity. Changed metadata, replacement assets, missing
logs, failed/skipped gates and untrusted source workflows cannot authorize signing.

The **Harmony release** GitHub App needs repository permissions **Actions: Read and
write** and **Contents: Read-only**, installed on both repositories. Approve the new
Contents permission before running the new source workflow. The token used here
is limited to Actions read and Contents read on the source repository. Temporary
handoffs are readable private prereleases because GitHub hides drafts from
read-only tokens; no source code write permission is needed.

Merge this publisher update before the matching source workflow update. Retry a
failed source run with all jobs. A successful source build is retained for seven
days for publisher retries, then the source cleanup workflow removes it. After
cleanup, start a new source Release run. Signing and published release formats,
promotion and withdrawal stay unchanged. No billing changes are required.
