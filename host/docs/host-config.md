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
- `nftables.service` is still **disabled**. Never enable it with the stock `flush ruleset` config; see section 4.
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

## 6. Facts that matter for later phases

- **The `nftables` package is installed** (nft 1.1.3), but `nftables.service` is **disabled and inactive**. The earlier recon wrongly reported nft as missing; it is in `/usr/sbin`, which isn't on the user PATH.
- **The default `/etc/nftables.conf` starts with `flush ruleset`.** Once Docker is installed, enabling or restarting `nftables.service` with that file would **delete Docker's firewall rules**. Docker's iptables-nft rules also live in nftables, so they would go too. Do not enable it until the firewall design accounts for this.
- `iptables` is not installed. The `docker-ce` package depends on it and will pull it in.
- `docker` group (gid 988) exists with no members. `/srv` is still empty (root:root 0755); Phase S hasn't run.
- User IDs: daniel 1000, axel 1001. The 2000–2999 range is reserved for service containers (D4).
- GitHub's SSH host key (from docs.github.com, checked 2026-11-09): Ed25519 `SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU`, ECDSA `SHA256:p2QAMXNIC1TJYWeIOttrVc98/R1BUFWu3/LiyKgUfQM`, RSA `SHA256:uNiVztksCsDhcc0u9e8BujQXVUpKZIDTMczCvj3tD2s`.
