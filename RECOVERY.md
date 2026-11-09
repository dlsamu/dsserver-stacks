# Rebuilding dsserver from scratch

For: a dead disk, a reinstall, or replacement hardware. Each step references the detailed record in `host/docs/host-config.md`. **Copy scripts to a temporary directory before running them with sudo**, so root never writes logs into the repository.

## 0. Prerequisites
- Debian 13 (trixie) netinstall, with KDE Plasma and an SSH server. First user: `daniel`, member of `sudo`.
- BIOS: After Power Loss → Power On.
- Router (Deco): DHCP reservation for the server's MAC address → 192.168.68.115.
- Access to the backup (NAS) and the restic password (backup phase); and GitHub accounts dlsamu and axelsamuelsson88.

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
sudo install -d -m 0700 -o root   -g root   /srv/appdata
sudo install -d -m 0750 -o daniel -g daniel /srv/stacks
git clone git@github-stacks:dlsamu/dsserver-stacks.git /srv/stacks
git -C /srv/stacks config user.name  "Daniel Samuelsson"
git -C /srv/stacks config user.email "ahdanielsamuelsson@gmail.com"
git -C /srv/stacks config core.hooksPath .githooks
```
Restore each service's `.env` and `secrets/` from the backup (they aren't in Git).

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
