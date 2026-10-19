# iNELS Harmony

Installation packages and updates for iNELS Harmony hotel servers.

[Latest stable release](https://github.com/elkoep-dev/harmony-releases/releases/latest) ·
[All releases and release notes](https://github.com/elkoep-dev/harmony-releases/releases)

## Install a new server

1. In Harmony Portal, open **Projects → New project**.
2. Copy the installation command provided for the project. It includes the
   registration token and checks the installer checksum before running it.
3. Run the command on the server with administrator privileges.

When installation finishes, the installer displays the addresses for
administration, reception and housekeeping.

Use the installer attached to a release or the command provided by Harmony Portal.
The `install.sh` in this repository's source tree is a legacy installer.

## Update an existing server

In the administration UI, open **Licensing → Update firmware**, select an available
version and start the update. The updater verifies the package and backs up the
database before applying changes.

For an older server without the built-in updater, open **Guides → Installation
guide** in Harmony Portal and use the upgrade command provided there.

On servers with `harmony-update`, you can check available updates and the result
of the last update from the command line:

```sh
sudo harmony-update check
sudo harmony-update status
```

Read the release notes before updating. Prereleases are candidates for testing;
use a stable release unless your installer has selected a candidate for your site.

## Release files

| File | Purpose |
|---|---|
| `install.sh` | Installer for a new server or an upgrade of an older installation |
| `harmony-X.Y.Z.tar.gz` | Installation and update package |
| `harmony-X.Y.Z.manifest.json` | Package version, size and checksum |
| `harmony-X.Y.Z.manifest.json.sig` | Digital signature checked by the installer and updater |
| `SHA256SUMS` | Checksums of the release files |

## Installation and update support

Contact your iNELS supplier or installer. Include the installed version, the error
message and the result of `sudo harmony-update status`, if available. Update logs
are stored in `/var/log/harmony-update.log`.
