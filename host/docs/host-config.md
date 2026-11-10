# dsserver: host configuration record

Host: dsserver, an HP EliteDesk 800 G6 Mini running Debian 13 (trixie) with KDE Plasma 6.3.
LAN: 192.168.68.115/24 on `eno1`, reserved in Deco DHCP. The gateway is 192.168.68.1.
Admin client: dsoffice (a Raspberry Pi, 192.168.68.121).

This is a temporary location. Move this file to `/srv/stacks/host/` once that Git repository exists.

---

## 1. Power management: never sleep (2026-11-09)

**Goal:** dsserver runs services 24/7, so it must never suspend, hibernate or hybrid-sleep. Display dimming, screen-off and screen locking keep working.

| Layer | Change | File or object |
|---|---|---|
| systemd sleep policy | `AllowSuspend=no`, `AllowHibernation=no`, `AllowHybridSleep=no`, `AllowSuspendThenHibernate=no` | `/etc/systemd/sleep.conf.d/90-dsserver-no-sleep.conf` (root:root 0644) |
| systemd targets | `sleep`, `suspend`, `hibernate`, `hybrid-sleep` and `suspend-then-hibernate` targets masked (linked to `/dev/null`) | `/etc/systemd/system/<name>.target` |
| KDE Plasma (user daniel) | `[AC][SuspendAndShutdown] AutoSuspendAction=0` ("Do nothing" when idle on mains power) | `~/.config/powerdevilrc` |

Not changed: `/etc/systemd/sleep.conf`, `logind.conf` (`IdleAction` is still `ignore`), the screen locker (no `kscreenlockerrc`, so defaults apply), and Plasma's display dim and off timers.

**Verified on 2026-11-09, including after a reboot:**
```bash
systemd-analyze cat-config systemd/sleep.conf | grep -v '^#'
for m in CanSuspend CanHibernate CanHybridSleep CanSuspendThenHibernate; do
  busctl call org.freedesktop.login1 /org/freedesktop/login1 org.freedesktop.login1.Manager $m; done   # all "no" (or "na")
systemctl is-enabled sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target  # all "masked"
kreadconfig6 --file powerdevilrc --group AC --group SuspendAndShutdown --key AutoSuspendAction   # 0
```

**Rollback** (removes only these changes):
```bash
sudo rm -f /etc/systemd/sleep.conf.d/90-dsserver-no-sleep.conf
sudo rmdir --ignore-fail-on-non-empty /etc/systemd/sleep.conf.d
sudo systemctl unmask sleep.target suspend.target hibernate.target hybrid-sleep.target suspend-then-hibernate.target
kwriteconfig6 --file powerdevilrc --group AC --group SuspendAndShutdown --key AutoSuspendAction --delete
systemctl --user restart plasma-powerdevil.service
```

**Still to do:** set "After Power Loss → Power On" in the BIOS (manual).

---

## 2. SSH: key-only login (2026-11-09)

### Phase A: key installed
- The private key was generated on dsoffice and lives only there. It is ED25519, with the comment `raspberrypi-to-dsserver`.
- `~/.ssh` is 0700 and `~/.ssh/authorized_keys` is 0600, both owned by daniel. The file holds exactly one key.
- Key fingerprint: `SHA256:Gqgm7XqorptPbPxG+3XUdhY1OrTswDip+ZEFkUP0TMQ`. This matches the key on dsoffice.

Host key fingerprints, to check when connecting from a new client:
```
ED25519  SHA256:+/4rFlI839owbE83HuwJmVzpClv7JcA/K3z0O8t8D4A
ECDSA    SHA256:1/qbeud4h0bOGI98QPqecTcK7rfInelteLsAe3QVelk
RSA      SHA256:CQuuimfAItzIaD1kJG2jU2bCq3nX34U+alPgxO3tqIc
```

### Phase B: passwords and root login turned off
File `/etc/ssh/sshd_config.d/10-dsserver-auth.conf` (root:root 0644, applied 2026-11-09 at 16:33:40):
```
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
```
`sshd_config` reads its drop-ins first (`Include` on line 12), so these settings take priority. The change was applied with a reload (`sshd -t`, then HUP), which left open sessions connected.

Not changed: the port (22 on all addresses), `X11Forwarding` (still `yes`), `AllowUsers` (unset) and the firewall.

**Verified on 2026-11-09:**
- Key login from dsoffice in a second connection after the reload works (confirmed by the user).
- Password-only login is rejected (confirmed by the user). A local test on the server also shows `daniel@127.0.0.1: Permission denied (publickey).`
- Root login with a password is rejected: `root@127.0.0.1: Permission denied (publickey).`

**Rollback.** Run this from an open SSH session or from the local console:
```bash
sudo rm -f /etc/ssh/sshd_config.d/10-dsserver-auth.conf
sudo sshd -t && sudo systemctl reload ssh
# Remove the key itself, if ever needed:
sed -i '/ raspberrypi-to-dsserver$/d' ~/.ssh/authorized_keys
```

**If you get locked out:** log in at dsserver's own keyboard and screen and run the rollback above.

**Possible later additions (each a separate change):** `X11Forwarding no` and `AllowUsers daniel`.

---

## 3. Docker Engine and Compose (2026-11-09)

Installed from Docker's official Debian 13 repository with the reviewed script (rev 2), at 16:56:16 to 16:56:29. Every check passed. Rev 1 had stopped at step 4 because of a false failure in its own check: under `pipefail`, `apt-cache madison | head -1` died with SIGPIPE. That run made no package changes.

### Repository
| Item | Value |
|---|---|
| Signing key | `/etc/apt/keyrings/docker.asc` (root:root 0644). Primary fingerprint `9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88`, "Docker Release (CE deb)" |
| Source | `/etc/apt/sources.list.d/docker.sources` (deb822): `https://download.docker.com/linux/debian`, suite `trixie`, component `stable`, `amd64`, `Signed-By` the key above |

### Packages (all from `download.docker.com … trixie/stable`)
| Package | Version |
|---|---|
| docker-ce, docker-ce-cli, docker-ce-rootless-extras | 5:29.9.3-1~debian.13~trixie |
| containerd.io | 2.4.2-3~debian.13~trixie |
| docker-compose-plugin | 5.7.0-1~debian.13~trixie (Compose v5.7.0) |
| docker-buildx-plugin | 0.38.1-1~debian.13~trixie |
| Pulled in from Debian | iptables 1.8.11-2, libip4tc2, libip6tc2, pigz 2.8-1 |

### Daemon configuration: `/etc/docker/daemon.json` (root:root 0644)
```json
{
  "firewall-backend": "iptables",
  "log-driver": "local"
}
```
- **Firewall backend: iptables**, the stable option, chosen explicitly. `iptables` points to `/usr/sbin/iptables-nft` (v1.8.11, nf_tables), so the rules live in the kernel's nftables. Docker's `DOCKER-USER` chain exists. The experimental nftables backend is **not** used; its `docker-bridges` table is absent.
- **Logging: `local` driver** with its default rotation (about 100 MB per container, kept as 5 files). Nothing is overridden.
- No other settings: no `live-restore`, `userland-proxy`, `data-root` or address pools.

### Runtime state as verified
- `docker` and `containerd` are enabled and running; `docker.socket` is enabled. They start at boot.
- Storage driver `overlayfs`. Cgroup driver `systemd`, cgroup v2. Docker's data folder is `/var/lib/docker` (root:root 0710) on the ext4 root filesystem.
- `/run/docker.sock` is root:docker 0660. The `docker` group (gid 988) has **no members**. daniel uses `sudo docker …`, as decided in D2, and gets "permission denied" without sudo, as intended.
- The `docker0` bridge is 172.17.0.1/16 and down (no containers), so it doesn't clash with the 192.168.68.0/24 LAN.
- `net.ipv4.ip_forward=1`. Docker sets this, along with an iptables `FORWARD` policy of DROP.
- **No new listening ports** compared with the pre-install baseline. No containers or images exist; the hello-world image was removed after the test.
- `nftables.service` is still **disabled**. Never enable it with the stock `flush ruleset` config; see section 8.
- No firewall rules have been added. No users were added to the `docker` group.

### Rollback
```bash
sudo apt purge docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker-ce-rootless-extras
sudo rm -f /etc/apt/sources.list.d/docker.sources /etc/apt/keyrings/docker.asc /etc/docker/daemon.json
sudo rmdir --ignore-fail-on-non-empty /etc/docker /etc/apt/keyrings
sudo apt update
# Images and data in /var/lib/docker and /var/lib/containerd are kept unless removed deliberately (destructive).
# A reboot clears ip_forward and the FORWARD policy.
```

---

## 4. Second user: axel (Phase U, 2026-11-09)

**Purpose:** remote development for Axel, from his Windows laptop using VS Code Remote-SSH. No admin rights. Kept separate from daniel and from the infrastructure.

Applied with `phaseU-axel.sh` (sha256 `4c306ef0…46d99`) at 18:51:09 to 18:51:10. It ran once and every check passed.

### Account
| Item | Value |
|---|---|
| User | `axel`, uid **1001**, own group `axel` (gid 1001), comment "Axel Samuelsson", shell `/bin/bash` |
| Groups | `axel`, `users` (adduser's default; grants nothing on this host). **Not** in `sudo`, `docker`, `adm` or `systemd-journal` |
| Password | None (`passwd -S` shows `L`), so no local, SDDM or `su` login. SSH key login works because of `UsePAM yes` (verified) |
| Home | `/home/axel` axel:axel **0700**. daniel can't list it (verified) |
| sudo | `User axel is not allowed to run sudo on dsserver.` |
| Docker | Denied: not in the `docker` group, socket is root:docker 0660 |
| Linger | Off, so axel's processes end when he disconnects |
| Created with | `adduser --disabled-password --uid 1001 --comment "Axel Samuelsson" axel` |

### SSH
| Item | Value |
|---|---|
| Client key | ED25519, comment `axel-laptop`, **`SHA256:Eu1cUiby9FhzPUb9bmRgwpyo/O8PC9GqyFagT5NzL50`**. Generated on the Windows laptop, where the private key stays. The fingerprint was checked by a separate channel; the Windows CRLF line ending was removed before install |
| Authorized keys | `/home/axel/.ssh` 0700 and `authorized_keys` 0600, both axel:axel, holding exactly this one key |
| Who may log in | `/etc/ssh/sshd_config.d/20-dsserver-users.conf` (root:root 0644): `AllowUsers daniel axel`. Applied with `sshd -t` and a reload. The settings sshd actually uses show `allowusers daniel` and `allowusers axel` |
| Still in force | Password, keyboard-interactive and root login are off (section 2). TCP forwarding is allowed, which VS Code port forwarding needs |
| Windows client | `%USERPROFILE%\.ssh\config` has `Host dsserver` → `192.168.68.115`, `User axel`, `IdentityFile ~/.ssh/id_ed25519_dsserver_axel`, `IdentitiesOnly yes`. Connect with VS Code Remote-SSH → `dsserver` |

### Resource limits for axel's processes
`/etc/systemd/system/user-1001.slice.d/50-limits.conf` (root:root 0644):
```ini
[Slice]
MemoryHigh=12G
MemoryMax=16G
CPUWeight=50
```
Applied: `MemoryHigh=12884901888` (12 GiB), `MemoryMax=17179869184` (16 GiB), `CPUWeight=50` (the default is 100). The drop-in is loaded alongside the default `/usr/lib/systemd/system/user-.slice.d/10-defaults.conf`.
- Above 12 GiB the kernel slows axel's processes and reclaims memory. At 16 GiB they are OOM-killed. Docker services run in `system.slice` and are unaffected.
- daniel's processes have no limit (admin). daniel's dev containers run under Docker, so they're also outside this limit.

### Verified on 2026-11-09
- Script checks: pre-flight, account, key, limits, sshd settings, isolation (sudo, docker, `/home/daniel`). The `/srv` checks were deferred because `/srv` didn't exist yet. **Repeat them after Phase S.**
- From Windows (user-reported): key login as axel works; `whoami` = axel; `hostname` = dsserver. Server record: `axel pts/4 from 192.168.68.126 at 18:53`.
- From dsoffice (user-reported): a fresh key-based login as daniel works and password-only login is rejected. The new daniel connection doesn't appear in `last`, probably because it was a command without a terminal, which `last` doesn't record. The server-side SSH log needs sudo: `sudo journalctl -u ssh --since 18:50`.
- Unaffected: docker and containerd are active, suspend is still refused, and no services have failed.

### Rollback (removes only these changes)
```bash
sudo rm -f /etc/ssh/sshd_config.d/20-dsserver-users.conf && sudo sshd -t && sudo systemctl reload ssh
sudo rm -f /etc/systemd/system/user-1001.slice.d/50-limits.conf
sudo rmdir --ignore-fail-on-non-empty /etc/systemd/system/user-1001.slice.d && sudo systemctl daemon-reload
sudo deluser --remove-home axel    # DESTRUCTIVE: deletes /home/axel; back it up first
```
To remove only axel's laptop key: `sudo sed -i '/ axel-laptop$/d' /home/axel/.ssh/authorized_keys`.

---

## 5. GitHub SSH authentication (Phase G, 2026-11-09): COMPLETE (verified 19:53)

**Principles:** each Linux user has their own keys and config. There is **no global Git author identity**; name and email are set per repository. `user.useConfigOnly=true` makes Git refuse to commit without that per-repo identity. SSH login settings are unchanged.

### daniel (created with `phaseG-daniel.sh`, sha256 `4c65a91b…d84a43`, at 19:11)
| Item | Value |
|---|---|
| `~/.ssh/github-dlsamu` | ED25519, **passphrase-protected**, `SHA256:3gA0HQxrO0pF22RoK62Z4IXcIg6Je4LHEAUqcBS1Ols`. For GitHub account **dlsamu** (Authentication key) |
| `~/.ssh/github-stacks-deploy` | ED25519, **no passphrase** (decision G1), `SHA256:DRRI0MERpJITxoB7MuJ2t69T66gJUJ8HhdmTI45Ye8E`. Deploy key for **dlsamu/dsserver-stacks** only, with write access |
| `~/.ssh/config` (0600) | `Host github.com` → `github-dlsamu`; `Host github-stacks` (HostName github.com) → `github-stacks-deploy`. Both use `IdentitiesOnly yes` |
| `~/.ssh/known_hosts` | GitHub Ed25519 pinned from docs.github.com. At 19:33:03 SSH added GitHub's RSA (`uNiV…D2s`) and ECDSA (`p2QA…UfQM`) host keys automatically; both match the published fingerprints. The previous version is kept as `known_hosts.old` |
| Global Git config | Only `user.useconfigonly=true` |

### axel (created with `phaseG-axel.sh`, sha256 `a3100287…c26722e`)
`~/.ssh/github-axelsamuelsson88` (passphrase-protected) for GitHub account **axelsamuelsson88**, plus his own `~/.ssh/config`, `known_hosts` and `user.useConfigOnly=true`. daniel can't read axel's home, by design, so these details are as reported by the user.

### Repository
`dlsamu/dsserver-stacks` is **private** and was created empty (per the user). Its remote for Phase S will be `git@github-stacks:dlsamu/dsserver-stacks.git`.

### Verification (final, 2026-11-09 19:53)
| Test | Result |
|---|---|
| daniel: `ssh -T git@github.com` as dlsamu | ✅ Passed, as reported by the user. Consistent with the successful github.com connection at 19:33 |
| axel: `ssh -T git@github.com` as axelsamuelsson88 | ✅ Passed, as reported by the user. daniel can't read axel's home, so this can't be checked independently |
| Deploy key: `ssh -T git@github-stacks` | ✅ `Hi dlsamu/dsserver-stacks! You've successfully authenticated, but GitHub does not provide shell access.` (exit 1 is normal) |
| Deploy key: read access, `git ls-remote git@github-stacks:dlsamu/dsserver-stacks.git` | ✅ exit 0, no refs (the repo is empty) |
| Deploy key: **write** access, checked without changing anything | ✅ `git-receive-pack` on the repo returned the push capability list (`report-status`, `delete-refs`, …), then was closed with a flush packet: exit 0, nothing sent. `ls-remote` afterwards still shows no refs |
| Deploy key: limited to this repo | ✅ Write to another repo is refused: `git-receive-pack 'git/git.git'` → `ERROR: Permission to git/git.git denied to deploy key`. Note that it **can read public repos** such as `git/git`, which anyone can. It can't write anywhere else |
| Global Git identity | ✅ None. Global config contains only `user.useconfigonly=true` |
| SSH login settings | ✅ Unchanged (`10-dsserver-auth.conf`, `20-dsserver-users.conf`) |

Problem fixed on the way: the deploy key was rejected at 19:40 because it hadn't been registered on GitHub correctly. After the user added it again it worked. No keys were regenerated.

### Rollback
- **On GitHub:** remove the deploy key (repo → Settings → Deploy keys) or an account key (Settings → SSH and GPG keys).
- **On dsserver, as the user concerned:** delete `~/.ssh/github-*`, the matching `Host` block in `~/.ssh/config`, and the github.com lines in `known_hosts`, then run `git config --global --unset user.useConfigOnly`.

---

## 6. `/srv/stacks` and `/srv/appdata` (Phase S, 2026-11-09)

### Layout and permissions
| Path | Owner / mode | Purpose |
|---|---|---|
| `/srv/stacks` | daniel:daniel **0750** | This Git repository. Commit as daniel, never with sudo. Directories inside are 0775 and files 0664 (daniel's umask); the 0750 parent keeps everyone else out, and group `daniel` has no members |
| `/srv/appdata` | root:root **0700** | Persistent container data, not in Git. Each service's directories are created by `host/bin/appdata-init` |

**Permission model, proven by the S1 probe:** a container running as uid 2001 could write through a bind mount to `/srv/appdata/_probe/data` (2001:2001 0750), even though `/srv/appdata` is 0700. The host showed the file as `2001:2001`. A container running as uid **2002 was refused**. So directory ownership is what grants access, and the 0700 parent doesn't get in the way. Probe image: `alpine:3.24.4@sha256:f59abe65…71bf`, run with `--network none --read-only` and removed afterwards along with the probe directory.

### Steps
| Step | When | How | Result |
|---|---|---|---|
| S1 | 20:13:02–04 | `phaseS-root.sh` (sudo, sha256 `a2551a6e…f04f31`) | Directories created, probe passed, cleanup verified, axel denied on both directories. For recovery it has been replaced by the idempotent `host/scripts/06-srv-dirs.sh` (S4a) |
| S2 | 20:14:31 | `phaseS-repo.sh` (daniel, sha256 `a944292c…908ffc`) | Host-file copies checked against the live files, repo-level identity set, hooks path set, first commit **`5c6117d7aeb6094660acc95d19e50fad0f326aeb`** (24 files) |
| S3 | 2026-11-09 | `git push -u origin main` with the deploy key | Remote `refs/heads/main` = `5c6117d…`. A fresh clone over the deploy key has the same commit and tree (`d2adab7`) and exactly 24 files, with modes and blob hashes identical to the local copy. Local working tree clean, tracking `origin/main` |

Repository settings (local only): `user.name=Daniel Samuelsson`, `user.email=ahdanielsamuelsson@gmail.com`, `core.hooksPath=.githooks`, `origin=git@github-stacks:dlsamu/dsserver-stacks.git`. There is still no global Git identity.

Pre-push checks: a scan of every tracked file for private-key blocks, GitHub/AWS/Slack tokens and credential assignments (password, secret, token or API key followed by `=` or `:` and a value) found nothing; the scan was confirmed to catch a planted key. No `.env` file except `templates/service/.env.example`. Neither private key's contents appear anywhere. The only key material is GitHub's public host key.

### Incident: `/srv/stacks` was world-readable for about one minute
- **What happened:** step 1 of `phaseS-repo.sh` ran `cp -a "$STAGE/." "/srv/stacks/"`. Copying `SRC/.` also applies the source directory's **own** mode to the target, so `/srv/stacks` changed from the approved **0750** to **0775** (others: r-x).
- **When:** about 20:14:30 to 20:15:20, found by the pre-S3 checks. Fixed with `chmod 0750 /srv/stacks` (daniel owns it, so no sudo was needed). That restored the approved S1 state, and the user was told.
- **Exposure:** while the mode was 0775, any local user could **read** (not write) the repository. axel was logged in at the time (from 18:53), and there's no way to tell whether he read it. The content had no secrets (scanned).
- **Script retired:** `phaseS-repo.sh` now starts with a guard that exits 1 ("retired after a permissions defect"), with the defect and a corrected pattern described in its header. It also can't succeed again anyway, because its pre-flight requires an empty `/srv/stacks` and an empty remote. **It is not in the repository. A rebuild uses `git clone`** (RECOVERY.md §2), which creates a fresh directory.
- **Corrected pattern, for any future copy into a protected directory:** copy the entries, not `dir/.`, and then enforce and verify the mode as the **last** step:
  `(shopt -s dotglob nullglob; cp -a -- "$SRC"/* "$DST"/) && chmod 0750 "$DST" && [ "$(stat -c %a "$DST")" = 750 ]`.
  Tested: the target stays 750; the old pattern produces 775.
- **Lesson:** check permissions after every step that writes into a protected directory, not only before it.

### Recovery script: `host/scripts/06-srv-dirs.sh` (added in S4a)
Idempotent. Run with `sudo bash 06-srv-dirs.sh [--no-probe]` from a copy outside the repo.
- **Missing** `/srv/appdata` or `/srv/stacks` are created (root:root 0700 and daniel:daniel 0750).
- **Existing** ones are only checked. A wrong owner or permission, a symlink or a plain file is reported and the script exits 1; it never changes ownership, permissions or contents.
- **Probe**, unless `--no-probe`: the uid 2001/2002 bind-mount test from S1. It refuses to run if `/srv/appdata/_probe` already exists, removes only what it created, and removes the probe image only if it wasn't there before.
- **Isolation:** every login user who isn't in `sudo` (currently axel) must be refused a listing of both directories.
- **Tested in test mode** (`SRV_ROOT=<scratch>`; skips ownership changes, the probe and the isolation check): created on the first run; no-op on the second, with contents untouched; a 0775 directory was reported with exit 1 and left at 0775; a symlink or file in place was refused; bad arguments exit 2; it refuses to run without sudo outside test mode. The probe and isolation steps reuse the commands that passed in S1. **They have not yet been run as root through this script.**

### Rollback
```bash
sudo rm -rf /srv/stacks && sudo rmdir /srv/appdata      # /srv/appdata must be empty
# GitHub: delete the main branch, or delete and recreate the empty repo (then re-add the deploy key)
```

---

## 7. Problems encountered, corrections and lessons (2026-11-09)

Raw run logs aren't kept in Git. This section records what they showed.

| # | Phase | Problem | Correction | Lesson |
|---|---|---|---|---|
| 1 | Recon | Reported "no nftables / nft"; the package **is** installed (`/usr/sbin` isn't on the user PATH) | Corrected in §8 facts. `nftables.service` is disabled, and its default config would `flush ruleset` | Check packages with `dpkg-query`, not just `command -v` |
| 2 | Docker plan | `gpg --show-keys` as daniel created an empty `~/.gnupg` (pubring, trustdb) | Disclosed. It's harmless and still present; delete it if unwanted. Later scripts use a throwaway `GNUPGHOME` | Read-only checks can still write state; isolate them |
| 3 | Docker install | Rev 1 stopped at step 4 with a **false** "candidate not from download.docker.com". Under `pipefail`, `apt-cache madison \| head -1` died of SIGPIPE (141). The same pattern could also have silently skipped `&& fail` checks | Rev 2: capture output to a variable, then match; a stricter origin check (every package, every origin of the candidate version); resumable. Rev 1 made no package changes | Never pipe into `head`, `grep -q` or `awk …exit` under `pipefail` |
| 4 | Phase U | The Windows `.pub` file had CRLF line endings | `sed -i 's/\r$//'` before install; fingerprint unchanged and checked again | Normalise keys that come from Windows |
| 5 | Phase G | Deploy key rejected (19:40): it wasn't registered on GitHub correctly | The user re-added it; no keys were regenerated; it verified at 19:53 | Compare the fingerprint GitHub shows with the local one |
| 6 | Phase G | The first write-access probe sent the flush too early, giving an inconclusive result | Repeated with the flush after the ref advertisement; it showed push capabilities and nothing was sent | Make protocol probes wait for the server |
| 7 | Phase S prep | The scratchpad (`/tmp`, tmpfs) was wiped at the 15:59 reboot, losing the power script | Recreated; it writes byte-identical output to the live file. All scripts are now in `host/scripts/` | Keep nothing that matters in `/tmp` |
| 8 | Phase S prep | `appdata-init` could create early directories before rejecting a later bad line | The parent-order check moved into the validation pass, so nothing is created on error (tested) | Validate everything before the first change |
| 9 | Phase S (S2) | `cp -a SRC/. DST/` made `/srv/stacks` 0775 for about 1 minute (**world-readable**) | Restored to 0750; script retired with an exit-1 guard; corrected pattern documented (§6) | Re-check permissions after every write into a protected directory |
| 10 | Phase S (pre-S3) | The first secret scan was invalid: a pattern starting with `-----` was parsed as an option | Rerun with `git grep -e …`; detector confirmed on a planted key; result clean | Pass regexes with `-e`; check that a scanner can actually catch something |
| 11 | A2 prep (2026-11-10) | `dsserver-reboot-needed --libs` first matched `.so` and `(deleted)` anywhere in a process's maps file, so memfd mappings (`/memfd:… (deleted)`) gave false positives (37 desktop processes) | The match is now per line: a `.so` file path ending in ` (deleted)`. A regression test was added | Match one line at a time, and test the negative case |
| 12 | NAS (2026-11-09/10) | The DATASERVER investigation (read-only; no logins) was **suspended**: the NAS is frozen during the Replay photo backup | Findings are in `docs/nas-replacement-requirements.md`; replacement NAS ordered | Never probe DATASERVER or Replay until told otherwise |

**Recovery instructions:** `RECOVERY.md`, using `host/scripts/01-…06-` in order. Each script stops on the first failed check and refuses to overwrite existing state.

---

## 8. Facts that matter for later phases

- **The `nftables` package is installed** (nft 1.1.3), but `nftables.service` is **disabled and inactive**. The earlier recon wrongly reported nft as missing; it is in `/usr/sbin`, which isn't on the user PATH (§7 #1).
- **The default `/etc/nftables.conf` starts with `flush ruleset`.** Once Docker is installed, enabling or restarting `nftables.service` with that file would **delete Docker's firewall rules**. Docker's iptables-nft rules also live in nftables, so they would go too. Do not enable it until the firewall design accounts for this.
- `iptables` is not installed. The `docker-ce` package depends on it and will pull it in.
- `docker` group (gid 988) exists with no members. `/srv` (root:root 0755) contains `stacks` and `appdata` (section 6).
- The scratchpad that held the review scripts is in `/tmp` (tmpfs) and **is wiped at reboot**. Durable copies of all host scripts are in `host/scripts/`.
- User IDs: daniel 1000, axel 1001. The 2000–2999 range is reserved for service containers (D4).
- GitHub's SSH host key (from docs.github.com, checked 2026-11-09): Ed25519 `SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU`, ECDSA `SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM`, RSA `SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s`.
- **Listening sockets baseline** (2026-11-09 before and after Docker, unchanged 2026-11-10): TCP `0.0.0.0:22`, `[::]:22`, `127.0.0.1:631`/`[::1]:631` (CUPS, local only), `*:1716` (KDE Connect, kept for now); UDP `*:1716`, mDNS `5353`, DHCPv6 client `546` on `eno1`, plus a few ephemeral desktop UDP ports. Installing Docker added no listening socket.
- **APT origins** (2026-11-10): `o=Debian` (trixie, trixie-updates, trixie-security) and `o=Docker` (download.docker.com trixie/stable). Nothing else.
- **unattended-upgrades 2.12** (Debian trixie), inspected without installing: installing it brings only `python3-distro-info`. Its debconf question `enable_auto_updates` defaults to **true**, and postinst then creates `20auto-upgrades` (daily lists + daily upgrade) through ucf. The default `50unattended-upgrades` allows `origin=Debian,codename=trixie,label=Debian` (point releases) and `…label=Debian-Security` only, so **not** trixie-updates and **not** Docker. It also installs `unattended-upgrades.service` (finishes a running upgrade at shutdown), a logind drop-in `InhibitDelayMaxSec=30`, and a kernel postinst hook that creates `/run/reboot-required`. Purging removes `20auto-upgrades` and `50unattended-upgrades`.
- **apt.systemd.daily** touches `/var/lib/apt/periodic/update-stamp` after a successful list update and `upgrade-stamp` after a successful unattended upgrade. Timers: `apt-daily` at 06:00/18:00 + up to 12 h random, `apt-daily-upgrade` at 06:00 + up to 60 min; both `Persistent=true`.
- **Scratchpad inventory** (`/tmp/claude-1000/…/scratchpad`, tmpfs, kept until cleanup is approved): install logs for Docker, Phase U and Phase S (results recorded in §3–§6 and §7), the retired `phaseS-repo.sh`, port snapshots (above), and verification clones. Nothing in it is needed to rebuild the host.


---

## 9. Automatic security updates (A1): DONE 2026-11-10 (verified 15:23)
**Result (2026-11-10):** run through delegated sudo (§11). preflight passed; install brought exactly `python3-distro-info 1.13` + `unattended-upgrades 2.12`, nothing removed; the package created `20auto-upgrades` and `50unattended-upgrades` and enabled `unattended-upgrades.service`. Verify passed: allowed origins `Debian`/`Debian-Security` for trixie only, Docker not allowed, Automatic-Reboot false, no mail. Pending updates at install time: **none** (`apt-get -s dist-upgrade`: 0 upgraded). Docker packages all at their candidate versions. No reboot needed (kernel 6.12.116+deb13-amd64). Then `hold` at 15:17:33: `apt-daily-upgrade.timer` stopped (still enabled) until `run-now` is approved; `verify` reports it as PAUSED. **Completed 15:22–15:23 (approved):** `run-now` → both services `success`, nothing to upgrade, stamps written (update 15:22:48, upgrade 15:22:58); `release` → timer active again (next 2026-11-11 06:30), hold marker removed; final `verify` passed with no PAUSED warning. Note: the log shows two unattended-upgrade starts per cycle, because `apt-daily` runs a download-only pass; that is normal.

Script `host/scripts/07-unattended-upgrades.sh` (steps: `preflight`, `install`, `verify`, `run-now`, `hold`, `release`, `status`, `rollback`). It is independent of Docker and of any NAS.

| Item | Setting |
|---|---|
| Package | `unattended-upgrades` 2.12 (+ `python3-distro-info`), `--no-install-recommends` |
| Schedule | `20auto-upgrades` from the package: package lists daily, unattended upgrade daily (via `apt-daily*.timer`) |
| Sources | package default: Debian point releases + Debian-Security for trixie. **Docker is not an allowed origin**; the Docker packages are also blacklisted as a second guard |
| Reboot | **never automatic** (`Automatic-Reboot "false"`, `…-WithUsers "false"`) |
| Mail | none (no MTA by design) |
| Our files | `/etc/apt/apt.conf.d/52dsserver-unattended-upgrades` (copy in `host/files/`), `/usr/local/sbin/dsserver-reboot-needed` (from `host/bin/`) |

**Is a reboot needed?** `dsserver-reboot-needed` (exit 1 = yes) reports `/run/reboot-required` (with packages) and a running kernel older than the newest installed. `dsserver-reboot-needed --libs` (with sudo) also lists processes still using replaced libraries; restarting those can be enough. A2 adds `reboot:required` as information to the heartbeat.

**Docker updates stay manual** (monthly, or when a Docker security advisory appears): `apt list --upgradable 2>/dev/null | grep -E 'docker|containerd'`, then plan an upgrade with the containers in mind.

**Verify:** `sudo bash 07-unattended-upgrades.sh verify` checks the config values, timers, our files against the repository, the dry run's allowed origins (Debian-Security present, Docker absent) and that no Docker package is in its upgrade list. Logs: `/var/log/unattended-upgrades/`, `journalctl -u apt-daily-upgrade`.

**Pause (`hold`) and resume (`release`):** `hold` stops `apt-daily-upgrade.timer` (it stays enabled, so a reboot resumes it) and writes the marker `/run/dsserver-a1-hold`. While held, `verify` prints a `WARN … PAUSED` line instead of failing, and `status` shows `PAUSED`. Package lists still refresh. Never leave a hold in place without a reason recorded here.

**Rollback:** `sudo bash 07-unattended-upgrades.sh rollback` saves copies to `/root/dsserver-rollback/07-<time>/`, removes our two files, purges the package (which removes `20auto-upgrades` and `50unattended-upgrades`) and checks that periodic upgrades are off.

## 10. Host health heartbeat (A2): DONE 2026-11-10 (enabled 15:55)
**Result (2026-11-10):** run through delegated sudo (§11, A2 added in c96dbde). preflight and install passed; installed files identical to the repository (root, 0755/0644), `/etc/dsserver-health` 0700; `systemd-analyze security` exposure 6.0 (expected: runs as root for smartctl). Local report before enabling: ok (NVMe SMART OK, root 2 %, apt stamps fresh, `docker:active` as info). Healthchecks.io check `dsserver-host`: period 5 min, grace 10 min, email to Gmail.
- **URL entry:** the hidden `set-url` prompt did not work for you in Konsole (cause not yet known). Workaround used: the URL was staged in `~/.ping-url.tmp` (0600), then `sudo install -m 0600 -o root -g root ~/.ping-url.tmp /etc/dsserver-health/ping-url && shred -u ~/.ping-url.tmp`. The URL was shared in the Claude chat by your choice (you accepted that; not rotated). It is not in Git or in any log.
- **enable** 15:55:25: first ping `status=ok` delivered, timer enabled.
- **test-fail** 15:55:38: `status=fail problems=test` delivered → **"down" email received**.
- **test-recover** 15:56:51: `status=ok` delivered → **"up" email received**.
- **test-silence** 15:58:36 (last ping 15:56:51): timer stopped → **"down" email received** after period + grace. **test-resume** 16:14:08: ping `status=ok` delivered, timer running again (every 5 min). This shows a silent or powered-off server is detected.

Design: `docs/monitoring-architecture.md`. Script `host/scripts/08-health-heartbeat.sh`; program `host/bin/dsserver-health`; units in `host/files/etc/systemd/system/`. Tests: `bash host/tests/test-dsserver-health.sh` (unprivileged; fakes; 47 checks).

**How it works:** `dsserver-health.timer` (2 min after boot, then every 5 min) runs `dsserver-health --ping` as a sandboxed one-shot root service (60 s timeout, `MemoryMax=64M`, read-only system). It evaluates the host and sends **one** HTTPS request to Healthchecks.io: the success URL, or `/fail` if a host problem exists. Healthchecks emails the Gmail inbox when the state changes, and also when pings stop (period 5 min + grace 10 min).

| Host problem (→ fail) | Information only |
|---|---|
| `failed_units` (any failed systemd unit except docker/containerd and itself), `disk_health` / `disk_unreadable` (smartctl -H), `disk_space` (root > 90%), `updates_stale` (no successful list update or upgrade in 72 h), `test` | `docker:<state>`; a deliberately stopped Docker is **not** a host failure. `reboot:required` |

**Host vs application availability:** this check answers "is the host alive and healthy". Applications (including Docker and containers) get their **own** checks later: one Healthchecks check per critical service, or Beszel. Until then a Docker crash is logged locally and shown as `docker:failed` in the ping body, but does not alert.

**Secrets and privacy:** the ping URL is in `/etc/dsserver-health/ping-url` (root 0600, directory 0700), entered with hidden input by `08 … set-url`, and not in Git. It reaches curl through a file descriptor, so it isn't on any command line or in `ps`, and it is never printed; curl's error text is discarded. The ping body contains only the codes above. Unit names, devices and percentages stay in the local journal: `journalctl -u dsserver-health`. curl: `--proto =https --tlsv1.2`, connect timeout 5 s, max 10 s per try, 2 retries, ≤ 30 s retrying.

**Healthchecks.io setup (by you, in a browser):** sign up with the Gmail address (it only receives); turn on two-factor login; create the check `dsserver-host`: Simple schedule, period **5 minutes**, grace **10 minutes**, integration **Email** (the account address). Copy its ping URL in the `https://hc-ping.com/<uuid>` form.

**Order:** `preflight` → `install` → (create the check) → `set-url` → `enable` → `test-fail` (expect a "down" email) → `test-recover` (expect "up") → optionally `test-silence` / wait 15+ min (expect "down") → `test-resume` (expect "up"). Tests touch only the heartbeat.

**Known limits:** it can't tell a home internet outage from a server outage. It doesn't see a failed application on a healthy host. If Healthchecks.io is down, nothing is detected. The free plan has 20 checks and keeps 100 log entries per check.

**Rollback:** `sudo bash 08-health-heartbeat.sh rollback` disables and removes the timer, service, program, test flag and the URL file. Then delete the check on healthchecks.io.

## 11. Delegated sudo for approved scripts: INSTALLED 2026-11-10 (commit 235d91d)
Installed by daniel in Konsole with the reviewed commit; snapshot hashes matched; sudo Defaults: `env_reset`, `mail_badpass`, `secure_path`, `use_pty`. Each delegated run appears in `journalctl _COMM=sudo` (verified).

Script `host/scripts/09-delegated-sudo.sh` (`show`, `install`, `remove`). Purpose: Claude Code (running as daniel, without a terminal for a password) can run approved, scripted operations directly, **without** general passwordless root for daniel.

| Item | Setting |
|---|---|
| Snapshot | `/usr/local/lib/dsserver-admin/` (root:root, 0755/0644): copies of the allowed scripts and the files they install, taken from the **reviewed commit** given to `install` (must equal HEAD). Repository edits change nothing until `install` is run again by you |
| Rule | `/etc/sudoers.d/dsserver-delegated` (0440, visudo-checked): `daniel ALL=(root) NOPASSWD:` the **exact command lines** in `COMMANDS` (script path + one fixed argument). No wildcards, shells, editors or `systemctl` |
| Currently allowed | `07-unattended-upgrades.sh` `preflight`, `install`, `verify`, `status`, `hold`, `release`, `run-now`; `08-health-heartbeat.sh` `preflight`, `install`, `enable`, `status`, `test-fail`, `test-recover`, `test-silence`, `test-resume`; `10-firewall.sh` `preflight`, `selftest-revert`, `try`, `confirm`, `verify`, `status`, `docker-test-start`, `docker-test-allow`, `docker-test-stop`. Not `rollback` (any), `set-url`, or `revert` (firewall) |
| Unchanged | daniel's normal `sudo` (with password); `env_reset`; root login disabled |

**Security review (2026-11-10), fixed before first install:**
- *Symlink hole:* scripts derived their file paths from `$0`. A link named `07-unattended-upgrades.sh` in a daniel-owned tree pointing to the snapshot would satisfy sudo (it matches by file identity), and the script would have installed an APT config and a binary from next to the link. That is arbitrary root execution. 07 and 08 now resolve their real location with `readlink -f`. Hard links are blocked by `fs.protected_hardlinks=1`.
- *Unpinned content:* `install` now takes the reviewed commit and refuses if HEAD differs.
- `git` runs as daniel with daniel's HOME, never as root; the temporary snapshot directory is removed on failure; `install` prints `sudo -l -U daniel` (including Defaults) for review.
- Checked: all directories on the paths used (/usr/local/{lib,sbin}, /etc/apt, /run, secure_path dirs) are root-owned and not group/world-writable; sudo 1.9.16 with `env_reset`, which strips `BASH_ENV`, `APT_CONFIG`, `LD_*`, `PYTHON*`; exact argument matching (one fixed argument, extra or missing arguments don't match).

**Risk accepted:** any process running as daniel can run exactly these commands without a password. Their worst effect is installing or upgrading packages from the signed Debian repositories (Docker excluded) and pausing/resuming the upgrade timer. Approval of *when* to run e.g. `run-now` stays with you; Claude asks first.

**Extending it** (e.g. A2): add the files and command lines to `FILES`/`COMMANDS`, commit, review, then run `sudo bash 09-delegated-sudo.sh install <commit>` yourself.

**Audit:** every use is logged by sudo: `journalctl _COMM=sudo -g dsserver-admin`. Package changes: `/var/log/apt/history.log`, `/var/log/unattended-upgrades/`. **Remove:** `sudo bash 09-delegated-sudo.sh remove`.

## 12. Host firewall (A3): DONE 2026-11-10 (enabled 17:02)
**Deployment (2026-11-10), through delegated sudo (§11, A3 added in b65b957):**
- Pre-checks: `eno1` = 192.168.68.115/24 as in the ruleset; `nftables.service` disabled; local console (KDE session on seat0, other VTs on demand) unaffected by the firewall; A1 active, A2 pinging ok.
- `selftest-revert` 16:42:12 (the script exited at once): the empty table was removed by PID 1 at 16:43:12. Docker's tables untouched.
- Baseline without the firewall: container DNS/internet/host-ssh reachable; from dsoffice (192.168.68.121) `curl :18080` → `dsserver-fwtest-ok`. Image `busybox:1.37.0` = `sha256:a7dbc319b1438115a207e11930dc4bb3e643dcb3ec0bdd694bb36cd8fad289ec`.
- First `try` 16:43:24: the client tests were run on dsserver itself by mistake (loopback bypasses the firewall, so they prove nothing). The **real automatic revert fired at 16:53:25** and removed the table as designed.
- Second `try` 16:58:10, tests from **dsoffice** (192.168.68.121): new SSH reached sshd (`Permission denied (publickey)`: BatchMode with no usable key; the TCP connection and SSH handshake got through), ping ok, `curl :18080` **timed out** (`exit=28`; log: `dsserver-fw published-drop: … SRC=192.168.68.121 … DST=172.17.0.2 DPT=8080`). After `docker-test-allow`: `curl` → `dsserver-fwtest-ok`. On the server: container DNS and internet reachable, container → host SSH **blocked**, host → 127.0.0.1:18080 reachable, host HTTPS ok, heartbeat ping 17:00:29 delivered.
- `confirm` 17:02:32: revert cancelled, `/etc/dsserver-firewall.nft` + unit installed, enabled at boot (`sysinit.target`), unit reloaded (the runtime 18080 element is gone). `verify` passed. `docker-test-stop`: container and image removed.
- Not tested: Windows (its battery was empty). New SSH from Windows (axel) is covered by the same LAN rule; check it at the next opportunity.

Script `host/scripts/10-firewall.sh`; ruleset `host/files/etc/dsserver-firewall.nft`; unit `dsserver-firewall.service`; application access: [docs/network-access.md](../../docs/network-access.md).

| Item | Setting |
|---|---|
| Mechanism | One nftables table, `inet dsserver_fw` (IPv4+IPv6), loaded by our own unit at boot (before `network-pre.target`). The file replaces only this table, atomically. **No `flush ruleset`**, and `nftables.service` stays disabled: Debian's `/etc/nftables.conf` flushes everything, including Docker's tables |
| Docker | Our chains run at priority −10, before Docker's (0). Our drops are final; our accepts still pass through Docker's rules. Docker (`iptables` backend) keeps its own tables untouched |
| Input | policy **drop**. Allowed: `lo`; replies; ICMP errors; ping from the LAN; IPv6 ND/RA/MLD and packet-too-big; IGMP from the LAN; DHCPv4 replies; DHCPv6 replies from link-local. Plus the access scopes: LAN = SSH 22/tcp, KDE Connect 1714–1764/tcp+udp, mDNS 5353/udp. Broadcast/multicast noise dropped silently; other drops logged (6/min, `dsserver-fw drop:`) |
| Forward | policy accept, but every NEW connection from `eno1`/VPN must be a Docker published port **in a scope**. Otherwise it is dropped (`dsserver-fw published-drop:` / `fwd-drop:`). Direct routing to container addresses is dropped. Containers' outgoing traffic is not affected |
| Containers → host | dropped (e.g. container → 172.17.0.1:22) |
| Outgoing | not filtered |
| If the unit fails at boot | No firewall (fail-open), and the heartbeat reports the failed unit (A2) |

**Automatic revert:** `try` first writes `/run/dsserver-firewall/rollback.nft` (the previous state of our table, or its removal), then schedules `nft -f rollback.nft` as a transient systemd timer (`dsserver-fw-revert.timer`, 600 s), and only then loads the new rules. The timer belongs to PID 1, so it fires even if the calling shell, sudo, the terminal or SSH dies. Until `confirm`, nothing is installed in `/etc` or enabled, so a reboot also removes the rules. `selftest-revert` proves the mechanism with an empty table (no chains, so no effect on traffic): the script schedules the removal and exits.

**Tests (no root):** `bash host/tests/test-firewall.sh` builds a throw-away user+network namespace: a server (`eno1` 192.168.68.115/24, `docker0`, a Docker-like NAT for 18080 → 172.17.0.2:80), a LAN client with a LAN and a non-LAN source address, and a container. It sends real TCP/UDP/ICMP/ICMPv6 traffic: **26 checks**, all passing (2026-11-10). This test found a real bug in the first draft: allowed published ports fell through to a drop.

**Live Docker test (during deployment):** `docker-test-start` runs `busybox:1.37.0` (non-root, read-only, no capabilities, 32 MB) publishing `0.0.0.0:18080`. It checks the container's DNS, internet, and container → host SSH, and host → 127.0.0.1:18080. LAN access is tested from dsoffice and Windows: blocked by default, open after `docker-test-allow` (runtime only). `docker-test-stop` removes the container, the image and the runtime element.

**Rollback:** after `confirm`: `sudo systemctl disable --now dsserver-firewall` (immediate), or fully: `sudo bash 10-firewall.sh rollback`. During `try`: wait for the automatic revert, or `sudo bash 10-firewall.sh revert`.

## 13. Tailscale client (handover M1): PREPARED 2026-11-10, not installed
**Purpose:** dsserver gets its own tailnet membership so it can administer kjells-computer (Kjell's Linux Mint laptop) without the Pi. Outgoing only: nothing on the tailnet can open a connection to dsserver.

Script `host/scripts/11-tailscale.sh` (run as root in Konsole; not in delegated sudo, so sudoers is unchanged). Steps: `preflight` (read-only), `install`, `up` (interactive login), `verify` (read-only), `status`, `rollback`. Log `/var/log/dsserver-tailscale.log` (root:daniel 0640; the login URL is shown on the terminal only). Baseline `/var/lib/dsserver-tailscale/` (root 0700).

| Item | Setting |
|---|---|
| Source | `pkgs.tailscale.com/stable/debian`, suite `trixie`, deb822 file `/etc/apt/sources.list.d/tailscale.sources`, `Signed-By: /usr/share/keyrings/tailscale-archive-keyring.gpg`. The key is accepted only with primary fingerprint **2596A99EAAB33821893C0A79458CA832957F5868** (Tailscale Inc. package repository signing key); every candidate/installed version must come only from that origin |
| Updates | **By hand** (`apt upgrade`), like Docker: unattended-upgrades (§9) only allows Debian origins |
| Tailnet | `tail96c1da.ts.net` (the user's account). `verify` fails if the node joined any other tailnet or did not get the name `dsserver` |
| Flags (`tailscale up`) | `--hostname=dsserver --accept-dns=false --accept-routes=false --ssh=false --shields-up --advertise-exit-node=false --exit-node= --advertise-routes=` |
| DNS | Not touched: `/etc/resolv.conf` stays with NetworkManager. MagicDNS names therefore don't resolve on dsserver; SSH config uses the tailnet IP plus `HostKeyAlias` |
| Firewall | **Unchanged.** `vpn_ifaces` stays empty, so new connections arriving on `tailscale0` hit the input policy drop; replies to our outgoing connections pass (`ct state established`). Peers can't use dsserver as a router (no advertised routes, no exit node), so the forward chain is not involved. `--shields-up` refuses incoming tailnet connections inside tailscaled as well. tailscaled adds its own `ts-*` iptables chains (via iptables-nft); our table's drops remain final |
| Sockets | tailscaled listens on UDP 41641 and a peer API on its tailnet address. New inbound from the LAN/internet to 41641 is dropped by our firewall; NAT traversal still works through outgoing packets (or Tailscale's DERP relays) |
| Key expiry | The user disables key expiry for `dsserver` in the Tailscale admin console after joining (`verify` warns until then) |
| Not used | Tailscale SSH, exit node, subnet routes, Funnel/Serve, MagicDNS on the host |

**Tests (no root):** `bash host/tests/test-tailscale-script.sh`: syntax, argument handling, key fingerprint (real repository key accepted; Docker's key and garbage rejected), approved prefs vs 11 deviations, route check (default route, LAN prefix, too-wide prefix flagged), resolv.conf check, socket diff, the approved flag set. **42 checks pass** (2026-11-10).

**Rollback:** `sudo bash 11-tailscale.sh rollback`: `tailscale logout`, purge the package, remove our sources file and keyring (only if they match ours) and the baseline; `/var/lib/tailscale` (created by the package) is left and reported. Then delete the dsserver machine in the admin console.

**Remote admin key (after joining):** a new Ed25519 key `~/.ssh/kjell_admin_dsserver`, **passphrase-protected** (interactive admin only; no unattended access from dsserver), generated by the user in Konsole. Its public line is appended (never replacing) to `~kjell/.ssh/authorized_keys` on kjells-computer over the Pi's existing connection, restricted with `from="<dsserver tailnet IP>"`. The Pi's key `mint_kjell` stays until Pi retirement. Fingerprints are recorded here once created.
