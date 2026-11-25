---
glean_provenance: {"generation_id":"e0567be987a841c891ba643b8d763f32.5","generated_at":"2026-11-25T19:50:49Z","model":"Glean Assistant 571.123"}
---
# Ops Manager Lab on a Mac (Apple container, 16 GB)

This lab installs a complete Ops Manager 8.0 environment inside a 16 GB Linux "container machine" on your Mac, created with Apple's [`container`](https://github.com/apple/container) tool. Two scripts do the work:

* `om-lab-mac.sh` runs on the Mac. It checks the Mac, builds an Ubuntu 24.04 image with systemd, creates the machine, checks it, and runs the lab script inside it.
* `setup-opsmanager-lab.sh` runs inside the machine (or on any Debian/Ubuntu x86_64 server). It installs the Application Database (AppDB) as a 3-member replica set, Ops Manager, and a first Global Owner user with an organization and a project.

This is a training lab, not a production deployment. All three AppDB members run on the same host, so you can practice elections and failover, but there is no real high availability.

Important: Ops Manager and this lab are x86_64 only, and Apple silicon Macs are ARM. The machine runs as `amd64` through Rosetta. This setup follows Apple's documentation, but nobody has tried it on a real Mac yet. Step 6 checks the machine and stops before installing anything if it is not usable.

## What gets installed


| Component       | Details                                                         | Port  |
| --------------- | --------------------------------------------------------------- | ----- |
| AppDB `appdb-1` | MongoDB Enterprise 8.0.x, replica set `appdbRS`, keyfile + auth | 27501 |
| AppDB `appdb-2` | Same as above                                                   | 27502 |
| AppDB `appdb-3` | Same as above                                                   | 27503 |
| Ops Manager     | Ops Manager 8.0.x (`mongodb-mms` package), HTTP                 | 8080  |
| Backup Daemon   | Started by Ops Manager, heap reduced to 1024 MB                 | n/a   |


Users created:

* `mongoadmin` on the AppDB, role `root` (Ops Manager uses it to connect to the AppDB).
* `omadmin` in Ops Manager, Global Owner, created through the API, plus the organization "Lab Org" and the project "Lab Project".

Why MongoDB 8.0 for the AppDB: Ops Manager 8.0 supports MongoDB 7.0 and 8.0 for its backing databases, but not 8.2 or 8.3 ([Ops Manager System Requirements](https://www.mongodb.com/docs/ops-manager/current/core/requirements/)). The script downloads MongoDB Enterprise 8.0.x as a tarball into `/opt/mongodb-appdb`.

## What you need on the Mac

* An Apple silicon Mac (M1 or later) with macOS 26. macOS 15 works with limits; the script warns you.
* At least 24 GB of physical RAM (32 GB recommended). The machine takes 16 GB, and macOS needs about 8 GB more. On a 16 GB Mac, see "Smaller Macs" below.
* Rosetta. The script offers to install it.
* Apple's `container` CLI. The script offers to install it with Homebrew (`brew install container`), or you can install the signed `.pkg` from the [releases page](https://github.com/apple/container/releases).
* About 20 GB of free disk space.
* Internet access (Ubuntu image, MongoDB 8.0 tarball, `mongosh`).
* The Ops Manager 8.0.x `.deb`. The scripts cannot download it by themselves.

## Quick start

1. Download Ops Manager from the [MongoDB Download Center](https://www.mongodb.com/try/download/ops-manager): Version 8.0.x, Platform "Debian 12, 13 / Ubuntu 22.04, 24.04", Package DEB. Leave it in `~/Downloads`. The right file is named like `mongodb-mms-8.0.x.<build>.amd64.deb` (about 1 GB). A file named `mongodb-mms-automation-agent-manager_...deb` is the MongoDB Agent, not Ops Manager, and the scripts ignore it.
2. Put `om-lab-mac.sh` and `setup-opsmanager-lab.sh` in the same folder (for example `~/om-lab`).
3. Open Terminal and run, as your normal user (no `sudo`):

```bash
cd ~/om-lab
bash om-lab-mac.sh
```

4. Answer the questions (install Rosetta or `container` if they are missing), then enter the two passwords when the lab asks for them:
   
   * `mongoadmin` (AppDB): at least 8 characters.
   * `omadmin` (Ops Manager): at least 8 characters, with one letter, one number and one special character.
5. Wait. Under Rosetta, the first start of Ops Manager can take 20 to 40 minutes.
6. The script opens `http://<machine-IP>:8080` in your browser. Log in as `omadmin`.

To skip the password prompts, pass them before the command: `APPDB_PWD='...' OM_ADMIN_PWD='...' bash om-lab-mac.sh`. They are written to a temporary file with mode 600, which is deleted as soon as the install ends.

## What `om-lab-mac.sh` does


| Step | Name                | What happens                                                                                                                                                                                                                                    |
| ---- | ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 1    | Check the Mac       | macOS version, Apple silicon, physical RAM (machine memory + 8 GB), Rosetta, `container` CLI. Offers to install Rosetta and `container`                                                                                                         |
| 2    | Start services, DNS | `container system start --enable-kernel-install` (only if not running). Checks that a container can resolve `archive.ubuntu.com`. If the default DNS fails, tries the Mac's DNS servers, then 1.1.1.1 and 8.8.8.8, and stops if none works      |
| 3    | Prepare files       | Copies `setup-opsmanager-lab.sh` and the `.deb` to `~/om-lab`, which the machine can see                                                                                                                                                        |
| 4    | Build the image     | Writes a `Dockerfile` (Ubuntu 24.04 + systemd) and runs `container build --arch amd64 -t local/om-lab-ubuntu:24.04`. If step 2 chose a DNS server, it restarts the builder with `--dns` and passes it to the build. Skipped if the image exists |
| 5    | Create the machine  | `container machine create --arch amd64 --cpus 4 --memory 16G --name om-lab local/om-lab-ubuntu:24.04`. Skipped if it exists                                                                                                                     |
| 6    | Check the machine   | `x86_64` architecture, systemd as PID 1, at least 15360 MB of memory, free disk, home folder mounted, DNS (fixes `/etc/resolv.conf` if needed), IP. Stops here if a check fails                                                                 |
| 7    | Install the lab     | Runs `sudo bash ~/om-lab/setup-opsmanager-lab.sh setup` inside the machine. If the lab is already installed, it starts it instead. Then it opens Ops Manager in the browser                                                                     |


You can run `bash om-lab-mac.sh` again at any time: steps that are already done are skipped.

## Commands (on the Mac)


| Command                     | What it does                                                                                           |
| --------------------------- | ------------------------------------------------------------------------------------------------------ |
| `bash om-lab-mac.sh`        | All 7 steps (same as `up`)                                                                             |
| `bash om-lab-mac.sh check`  | Checks the Mac, and the machine if it exists. Installs nothing                                         |
| `bash om-lab-mac.sh status` | Machine list plus the lab status (AppDB members and Ops Manager)                                       |
| `bash om-lab-mac.sh start`  | Boots the machine, starts the AppDB, updates the Ops Manager URL if the IP changed, starts Ops Manager |
| `bash om-lab-mac.sh stop`   | Stops Ops Manager and the AppDB, then the machine, so macOS gets its memory back                       |
| `bash om-lab-mac.sh open`   | Opens Ops Manager in the browser                                                                       |
| `bash om-lab-mac.sh shell`  | Opens a shell inside the machine                                                                       |
| `bash om-lab-mac.sh delete` | Deletes the machine and all lab data (asks first). `IMAGE=1` also deletes the image                    |
| `bash om-lab-mac.sh help`   | Shows the built-in help                                                                                |


Always stop the lab with `bash om-lab-mac.sh stop` when you finish. Running `container machine stop` directly can stop Ops Manager without its AppDB in the right order.

Inside the machine (`bash om-lab-mac.sh shell`), the lab commands are also available:


| Command                                                     | What it does                                                                   |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `sudo bash ~/om-lab/setup-opsmanager-lab.sh status`         | Each AppDB member (service, PRIMARY/SECONDARY) and the Ops Manager HTTP status |
| `sudo bash ~/om-lab/setup-opsmanager-lab.sh stop`           | Stops in order: Ops Manager, then the AppDB members                            |
| `sudo bash ~/om-lab/setup-opsmanager-lab.sh start`          | Starts in order: AppDB, waits for a PRIMARY, then Ops Manager                  |
| `sudo bash ~/om-lab/setup-opsmanager-lab.sh url`            | Shows `mms.centralUrl`                                                         |
| `sudo bash ~/om-lab/setup-opsmanager-lab.sh set-url [HOST]` | Changes `mms.centralUrl` (default: the machine IP) and restarts Ops Manager    |
| `sudo bash ~/om-lab/setup-opsmanager-lab.sh reset`          | Deletes the lab and uninstalls Ops Manager (asks you to type `DELETE`)         |


## Options for `om-lab-mac.sh`

Put the variables before the command, for example `MACHINE_CPUS=6 bash om-lab-mac.sh`.


| Variable         | Default                   | Purpose                                                                                                                                            |
| ---------------- | ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| `OM_DEB`         | auto                      | Ops Manager `.deb`. If not set: newest `mongodb-mms*.deb` in `~/om-lab`, `~/Downloads` or the current folder                                       |
| `OM_URL`         | none                      | Download link for the `.deb`, used instead of `OM_DEB`                                                                                             |
| `MACHINE`        | om-lab                    | Machine name                                                                                                                                       |
| `MACHINE_MEMORY` | 16G                       | Machine memory. The lab needs at least 15360 MB inside                                                                                             |
| `MACHINE_CPUS`   | 4                         | Machine vCPUs                                                                                                                                      |
| `IMAGE_TAG`      | local/om-lab-ubuntu:24.04 | Image name                                                                                                                                         |
| `WORK_DIR`       | \~/om-lab                 | Folder shared with the machine. Must be inside your home folder                                                                                    |
| `REBUILD`        | 0                         | Set to `1` to rebuild the image                                                                                                                    |
| `FORCE_RAM`      | 0                         | Set to `1` to continue on a Mac with less RAM than the machine + 8 GB                                                                              |
| `OPEN_BROWSER`   | 1                         | Set to `0` to not open the browser                                                                                                                 |
| `IMAGE`          | 0                         | With `delete`: set to `1` to also delete the image                                                                                                 |
| `DNS_SERVERS`    | auto                      | DNS server(s) for the image build and the machine, for example `DNS_SERVERS=10.1.2.3`. Use it when the automatic choice fails (VPN, corporate DNS) |


These lab variables are passed to the machine: `APPDB_PWD`, `OM_ADMIN_PWD`, `OM_ADMIN_USER`, `OM_HEAP_MB`, `DAEMON_HEAP_MB`, `APPDB_CACHE_GB`, `MONGO_VERSION`, `MONGOSH_VERSION`, `CREATE_OM_USER`, `OM_WAIT_MIN`, `OM_URL`, `LOW_RAM`. See the next section.

## Options for `setup-opsmanager-lab.sh`


| Variable          | Default       | Purpose                                                                                                                                 |
| ----------------- | ------------- | --------------------------------------------------------------------------------------------------------------------------------------- |
| `OM_DEB`          | auto          | Path to the Ops Manager `.deb`. If not set, the script looks for `mongodb-mms*.deb` in the current folder, your home folder and `/root` |
| `OM_URL`          | none          | Download link for the Ops Manager `.deb` (used instead of `OM_DEB`)                                                                     |
| `MONGO_VERSION`   | newest 8.0.x  | AppDB version. Only 8.0.x is accepted                                                                                                   |
| `MONGOSH_VERSION` | 2\.14.3       | `mongosh` version to install if it is missing                                                                                           |
| `APPDB_CACHE_GB`  | 0\.5          | WiredTiger cache per AppDB member                                                                                                       |
| `OM_HEAP_MB`      | 8096          | Ops Manager heap (the Ops Manager default)                                                                                              |
| `DAEMON_HEAP_MB`  | 1024          | Backup Daemon heap                                                                                                                      |
| `LOW_RAM`         | 0             | Set to `1` to allow the reduced 7 GB profile                                                                                            |
| `APPDB_PWD`       | prompted      | Password for `mongoadmin`                                                                                                               |
| `OM_ADMIN_USER`   | omadmin       | First Ops Manager user                                                                                                                  |
| `OM_ADMIN_PWD`    | prompted      | Password for the first Ops Manager user                                                                                                 |
| `OM_HOST`         | `hostname -f` | Host name written to `mms.centralUrl`. On Apple container the default is the machine IP                                                 |
| `OM_WAIT_MIN`     | 20            | Minutes to wait for Ops Manager to answer. 40 on Apple container                                                                        |
| `CREATE_OM_USER`  | 1             | Set to `0` to skip creating the first user, organization and project                                                                    |
| `IGNORE_SHARDED`  | 0             | Set to `1` to run even if the sharded lab is running (not recommended)                                                                  |
| `FORCE`           | 0             | Set to `1` to skip the `DELETE` confirmation in `reset`                                                                                 |
| `PURGE_BINARIES`  | 0             | Set to `1` so `reset` also deletes the MongoDB 8.0 binaries in `/opt/mongodb-appdb`                                                     |


## Memory sizing


| &nbsp;                 | 16 GB profile (default) | 7 GB profile (`LOW_RAM=1`) |
| ---------------------- | ----------------------- | -------------------------- |
| Ops Manager heap       | 8096 MB                 | 2304 MB                    |
| Backup Daemon heap     | 1024 MB                 | 768 MB                     |
| Cache per AppDB member | 0\.5 GB                 | 0\.25 GB                   |
| Estimated use          | about 13 GB             | about 6.4 GB               |
| Free margin            | about 2.5 to 3 GB       | about 0.6 GB               |


The script stops if the system reports less than 15 GB, unless you set `LOW_RAM=1`.

The 7 GB profile is below the documented minimum: Ops Manager asks for 15 GB of RAM and recommends not setting the heap below 8096 MB ([Ops Manager System Requirements](https://www.mongodb.com/docs/ops-manager/current/core/requirements/), [Host Issues](https://www.mongodb.com/docs/ops-manager/current/reference/troubleshooting/system/)). Use it only if you cannot get a 16 GB machine, and expect slowness or `OutOfMemoryError`.

Even with 16 GB there is not much room left. Adding a blockstore or oplog store replica set for backups (3 more `mongod`) will make memory tight; 24 GB or more is better for that.

### Smaller Macs

On a Mac with 16 GB of RAM, a 16 GB machine leaves nothing for macOS. You can try the reduced profile, knowing that it is below the documented minimum:

```bash
MACHINE_MEMORY=8G LOW_RAM=1 FORCE_RAM=1 bash om-lab-mac.sh
```

## How the machine works

* A container machine is a persistent Linux VM that runs the image's own init (systemd), so the lab's systemd services work ([Container machine](https://github.com/apple/container/blob/main/docs/container-machine.md)).
* Your Mac home folder is mounted inside the machine at the same path (`/Users/<you>`), and your user has passwordless `sudo`. This is how the machine sees `~/om-lab`.
* The machine gets its own IP on a private network (usually `192.168.64.x`). The Mac reaches Ops Manager at `http://<machine-IP>:8080`, and the lab writes that IP to `mms.centralUrl`.
* The IP can change after the machine restarts. For that reason, Ops Manager does not start by itself at boot on Apple container. `bash om-lab-mac.sh start` updates the URL to the current IP and then starts Ops Manager. To use a fixed name instead, set `OM_HOST` during the install or run `set-url <name>` later.
* The machine keeps its data when stopped. Only `delete` removes it.
* DNS: containers use the container network's DNS by default. If that does not answer (common with a VPN), the script picks another server and writes it to the machine's `/etc/resolv.conf`. The machine can reset that file at boot, so `bash om-lab-mac.sh start` checks DNS again.

## Running on a Linux server instead

`setup-opsmanager-lab.sh` also works by itself on Debian 12, Ubuntu 22.04 or Ubuntu 24.04 (x86_64), with at least 15 GB of RAM reported by the system, root access, and free ports 8080, 8443 and 27501 to 27503.

```bash
sudo OM_DEB=~/mongodb-mms-8.0.x.deb bash setup-opsmanager-lab.sh
```

Then open `http://<server-hostname>:8080`. On Linux, the first start takes up to 15 minutes and Ops Manager starts at boot.

Do not run it next to the sharded cluster lab (`setup-sharded-lab.sh`): together they need more than 16 GB. The script stops if `mongos-lab` or any `mongod-lab@*` service is running; run `sudo bash setup-sharded-lab.sh stop` first. Both labs use different ports, folders and service names, so you can switch between them with `stop` and `start`.

## Files and folders


| Path                                        | Content                                                                          |
| ------------------------------------------- | -------------------------------------------------------------------------------- |
| `/etc/mongodb-om-lab/appdb-*.conf`          | Configuration of each AppDB member                                               |
| `/etc/mongodb-om-lab/keyfile`               | Keyfile for internal authentication of `appdbRS`                                 |
| `/etc/mongodb-om-lab/lab.env`               | Saved settings (version, cache, heap, profile) used by `start`, `stop`, `status` |
| `/etc/mongodb-om-lab/om-api.env`            | Global Owner API key, organization ID, project ID and agent API key (root only)  |
| `/data/om-appdb/appdb-*`                    | AppDB data                                                                       |
| `/var/log/mongodb/appdb-*.log`              | AppDB logs                                                                       |
| `/opt/mongodb-appdb/<version>`              | MongoDB 8.0 binaries; `/opt/mongodb-appdb/current` points to the active one      |
| `/etc/systemd/system/appdb-lab@.service`    | systemd template for the AppDB members                                           |
| `/opt/mongodb/mms/conf/conf-mms.properties` | Ops Manager settings (original saved as `.orig`)                                 |
| `/opt/mongodb/mms/conf/mms.conf`            | Ops Manager JVM settings (original saved as `.orig`)                             |
| `/opt/mongodb/mms/logs/mms0.log`            | Ops Manager application log                                                      |
| `/var/tmp/om-lab`                           | Copy of the `.deb` when it comes from the Mac home folder                        |


On the Mac, `~/om-lab` holds the two scripts, the `.deb` and the generated `Dockerfile`.

## After the install

Open a shell in the machine with `bash om-lab-mac.sh shell`, then connect to the AppDB:

```bash
mongosh "mongodb://localhost:27501,localhost:27502,localhost:27503/admin?replicaSet=appdbRS" -u mongoadmin -p
```

Check the replica set (expected result: 5, one PRIMARY = 1 plus two SECONDARY = 2 + 2):

```javascript
rs.status().members.reduce((a, v) => a + v.state, 0)
```

Use the saved API key:

```bash
sudo bash -c 'source /etc/mongodb-om-lab/om-api.env && curl -s --digest -u "$OM_PUB_KEY:$OM_PRIV_KEY" "$OM_URL/api/public/v1.0/groups/$OM_PROJECT_ID"'
```

Ops Manager settings applied in `conf-mms.properties`:

* `mms.ignoreInitialUiSetup=true`, so the setup wizard is skipped. All required settings (central URL, client certificate mode, email addresses, mail transport) are included ([Ops Manager Configuration Settings](https://www.mongodb.com/docs/ops-manager/current/reference/configuration/)). The email values are fake; no mail server is needed.
* `mms.user.invitationOnly=true`, required by the API call that creates the first user ([Create the First User](https://www.mongodb.com/docs/ops-manager/current/reference/api/user-create-first/)).
* `automation.versions.source=hybrid`: the MongoDB Agents download MongoDB binaries from Ops Manager, and Ops Manager downloads them from the internet.

## Troubleshooting

### On the Mac


| Symptom                                             | What to do                                                                                                                                                                                                                                                                                                                     |
| --------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| "Do not use sudo"                                   | Run `bash om-lab-mac.sh` as your normal user. The script uses `--root` inside the machine when it needs to                                                                                                                                                                                                                     |
| "The machine takes 16G and macOS needs \~8 GB more" | Use a Mac with more RAM, or see "Smaller Macs"                                                                                                                                                                                                                                                                                 |
| "No Ops Manager .deb found"                         | Download it to `~/Downloads`, or pass `OM_DEB=/path/to/file.deb`                                                                                                                                                                                                                                                               |
| "... is the MongoDB Agent, not Ops Manager"         | You downloaded `mongodb-mms-automation-agent-manager_...deb`. Download the Ops Manager package (`mongodb-mms-8.0.x...amd64.deb`) instead                                                                                                                                                                                       |
| The build says "Temporary failure resolving"        | DNS does not work in the image builder. Run `bash om-lab-mac.sh check` to see which DNS servers answer, then `DNS_SERVERS=<ip> bash om-lab-mac.sh`. To make it permanent, add `[container.dns]` with `nameservers = ["<ip>"]` to `~/.config/container/config.toml`, then run `container system stop && container system start` |
| "No DNS server works from inside a container"       | Usually a VPN or a security agent (for example Zscaler) that blocks the container network. Disconnect or pause it and try again, or ask IT for an internal DNS server for `DNS_SERVERS`. If the network also needs an HTTP proxy, DNS alone will not fix it                                                                    |
| `container build` fails for another reason          | Run `container system start` and try again with `REBUILD=1`                                                                                                                                                                                                                                                                    |
| Step 6: architecture is `aarch64`                   | The machine is not running as x86_64. Ops Manager is not packaged for ARM, so the lab cannot run. Use an x86_64 Linux VM                                                                                                                                                                                                       |
| Step 6: PID 1 is not systemd                        | The image or Rosetta setup is not working. Delete the machine (`bash om-lab-mac.sh delete`) and run `REBUILD=1 bash om-lab-mac.sh`                                                                                                                                                                                             |
| Step 6: memory inside is too low                    | `container machine set -n om-lab memory=17G`, then `container machine stop om-lab` and `bash om-lab-mac.sh` again                                                                                                                                                                                                              |
| Step 6: home folder not visible                     | Your home folder is not mounted. Re-create the machine (`delete`, then `bash om-lab-mac.sh`)                                                                                                                                                                                                                                   |
| "mongod stopped with 'Illegal instruction'"         | Rosetta does not provide AVX, which MongoDB 5.0+ needs on x86_64. Update macOS (Rosetta added AVX/AVX2 in macOS 15)                                                                                                                                                                                                            |
| Ops Manager's Java crashes with `SIGSEGV`           | x86 Java under Rosetta has had crashes like this before. Use an x86_64 Linux VM                                                                                                                                                                                                                                                |
| The browser cannot open Ops Manager after a restart | The IP changed. Run `bash om-lab-mac.sh start`, or inside the machine `sudo bash ~/om-lab/setup-opsmanager-lab.sh set-url`                                                                                                                                                                                                     |
| The Mac is slow                                     | Stop the lab with `bash om-lab-mac.sh stop` when you are not using it                                                                                                                                                                                                                                                          |


### In the lab


| Symptom                                                      | What to check                                                                                                                             |
| ------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------- |
| "This script is sized for 16 GB..."                          | The system reports less than 15 GB. Check `free -h`. Give the machine more memory or use `LOW_RAM=1`                                      |
| "Expected an Ops Manager 8.0.x package"                      | The `.deb` is another version. This lab only covers 8.0.x                                                                                 |
| "MONGO_VERSION must be 8.0.x"                                | 8\.2 and 8.3 are not supported for the AppDB. Use an 8.0.x version                                                                        |
| "Port ... is in use"                                         | Find the process with `sudo ss -ltnp`                                                                                                     |
| "A lab already exists" or "Ops Manager is already installed" | Run `sudo bash ~/om-lab/setup-opsmanager-lab.sh reset` inside the machine, then `bash om-lab-mac.sh` again                                |
| Ops Manager does not answer in time                          | Look at `/opt/mongodb/mms/logs/mms0.log` and `mms0-startup.log`. Under Rosetta you can wait longer with `OM_WAIT_MIN=60`                  |
| `OutOfMemoryError` in `mms0.log`                             | Raise `OM_HEAP_MB` or reduce `APPDB_CACHE_GB`, then `reset` and set up again, or edit `mms.conf` and restart `mongodb-mms`                |
| The first user could not be created through the API          | Set `mms.user.invitationOnly=false` in `conf-mms.properties`, run `sudo systemctl restart mongodb-mms`, and use Sign Up on the login page |
| An AppDB member does not start                               | `sudo tail -n 50 /var/log/mongodb/appdb-1.log`                                                                                            |


## Lab limitations

* Everything runs on one machine, so the AppDB has no real high availability.
* On a Mac, everything runs as x86_64 under Rosetta: it is slower than native, and it is not a supported platform for Ops Manager.
* The keyfile is generated with `openssl` on each install.
* The AppDB password is stored in plain text inside `mongo.mongoUri`, in a file only root can read (mode 600). You can encrypt it with Ops Manager's `credentialstool` as a class exercise.
* No TLS and no HTTPS: Ops Manager runs on HTTP port 8080.
* The automation agent, backup (blockstore and oplog store), LDAP and local mode are not installed. The project ID and agent API key are saved in `om-api.env` so you can add the agent later.

## Status of testing

Both scripts pass `bash -n`. `setup-opsmanager-lab.sh` was run end to end in a simulation with fake `systemctl`, `mongosh`, `curl` and `apt`, in Linux mode and in Apple container mode. `om-lab-mac.sh` was run with a fake `container` CLI and fake macOS commands. Neither script has been run on a real Mac or server yet. In particular, systemd and Ops Manager's Java under Rosetta are not verified. Run the whole lab once on your Mac before using it in class.

## Sources

* [Ops Manager System Requirements](https://www.mongodb.com/docs/ops-manager/current/core/requirements/)
* [Install the Ops Manager Application Database and Backup Database](https://www.mongodb.com/docs/ops-manager/current/tutorial/prepare-backing-mongodb-instances/)
* [Install Ops Manager with a deb Package](https://www.mongodb.com/docs/ops-manager/current/tutorial/install-on-prem-with-deb-packages/)
* [Ops Manager Configuration Settings](https://www.mongodb.com/docs/ops-manager/current/reference/configuration/)
* [Create the First User (API)](https://www.mongodb.com/docs/ops-manager/current/reference/api/user-create-first/)
* [Host Issues (Java heap)](https://www.mongodb.com/docs/ops-manager/current/reference/troubleshooting/system/)
* [Install MongoDB Enterprise on Ubuntu (tarball)](https://www.mongodb.com/docs/v8.0/tutorial/install-mongodb-enterprise-on-ubuntu-tarball/)
* [Apple container: Container machine](https://github.com/apple/container/blob/main/docs/container-machine.md)
* [Apple container: Command reference](https://github.com/apple/container/blob/main/docs/command-reference.md)
* [Apple container: Networking](https://github.com/apple/container/blob/main/docs/networking.md)

