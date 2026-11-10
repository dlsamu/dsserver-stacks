# Rebuilding dsserver from scratch

For: a dead disk, a reinstall, or replacement hardware. Each step references the detailed record in `host/docs/host-config.md`. **Copy scripts to a temporary directory before running them with sudo**, so root never writes logs into the repository. (Scripts 07 and 08 are the exception: they write nothing into the repository and run in place.)

## 0. Prerequisites
- Debian 13 (trixie) netinstall, with KDE Plasma and an SSH server. First user: `daniel`, member of `sudo`.
- BIOS: After Power Loss → Power On.
- Router (Deco): DHCP reservation for the server's MAC address → 192.168.68.115.
- Access to the backup (NAS) and the restic password (backup phase); and GitHub accounts dlsamu and axelsamuelsson88.

## 0b. Get a bootstrap copy of this repository
The scripts below are in this repository, but cloning it needs the GitHub keys that script 05 creates. Get a first copy in **one** of these ways and unpack it to `~/bootstrap` (as daniel):
- from the NAS backup of `/srv/stacks` (backup phase), or
- in a browser on the KDE desktop, logged in as **dlsamu**: github.com/dlsamu/dsserver-stacks → Code → **Download ZIP**.

Run every script from `~/bootstrap/host/scripts/` (or a copy in `/tmp`), never from inside `/srv/stacks`. Delete `~/bootstrap` after step 2.

## 1. Host base (in order; each script stops on the first failed check)
| Step | Script / action | Record |
|---|---|---|
| Power | `sudo sh 01-power-no-sleep.sh`, plus the Plasma `kwriteconfig6` line in its header | §1 |
| SSH keys | From dsoffice: `ssh-copy-id -i ~/.ssh/id_ed25519_dsserver.pub daniel@<host>` (password login still works at this point) | §2 |
| SSH key-only | `sudo sh 02-ssh-keyonly.sh` (keep one session open; test from a second one) | §2 |
| Docker | `sudo bash 03-docker-install.sh` | §3 |
| User axel | `sudo bash 04-user-axel.sh <axel.pub> <SHA256 fingerprint>` (the key comes from axel's Windows PC) | §4 |
| GitHub | As daniel: `bash 05-github-daniel.sh`; as axel: `bash 05-github-axel.sh`. Then register the printed public keys on GitHub (the deploy key with write access) | §5 |

Then compare the live files with `host/files/`, for example: `diff -r host/files/etc/ssh/sshd_config.d /etc/ssh/sshd_config.d`.

## 2. This repository
```bash
# Creates /srv/appdata (root 0700) and an empty /srv/stacks (daniel 0750), or only verifies them if they exist;
# runs the uid 2001/2002 bind-mount probe and the non-admin isolation check. Idempotent; changes nothing that exists.
sudo bash ~/bootstrap/host/scripts/06-srv-dirs.sh
git clone git@github-stacks:dlsamu/dsserver-stacks.git /srv/stacks      # as daniel, into the empty directory
stat -c '%a %U:%G' /srv/stacks                                          # must still be: 750 daniel:daniel
git -C /srv/stacks config user.name  "Daniel Samuelsson"
git -C /srv/stacks config user.email "ahdanielsamuelsson@gmail.com"
git -C /srv/stacks config core.hooksPath .githooks
```
Restore each service's `.env` and `secrets/` from the backup (they aren't in Git).

## 2b. Host services that come from this repository
| Step | Commands (as root, from `/srv/stacks/host/scripts`) | Record |
|---|---|---|
| Security updates | `sudo bash 07-unattended-upgrades.sh install`, then `… run-now` | host-config §9 |
| Delegated sudo (optional) | `sudo bash 09-delegated-sudo.sh install` (after the repository is cloned and at the right commit) | host-config §11 |
| Heartbeat | `sudo bash 08-health-heartbeat.sh install`, then `set-url` (the URL is on the check's page at healthchecks.io), `enable`, `test-fail`, `test-recover` | host-config §10 |

## 3. Data
- Restore `/srv/appdata` from the backup with owners and permissions preserved (backup phase documents the exact command).
- Or, for an empty start, run `sudo host/bin/appdata-init <service>` for each service.

## 4. Services
For each service in this order: <none yet>
```bash
cd /srv/stacks/<service> && sudo docker compose up -d && sudo docker compose ps
```

## 5. Checks
- Each service is `healthy`.
- `ss -tuln` shows only the expected ports.
- Suspend is refused: `busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager CanSuspend` returns `"no"`.
- Password SSH login is refused, and `ssh -T git@github-stacks` returns `Hi dlsamu/dsserver-stacks!`.
