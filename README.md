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
