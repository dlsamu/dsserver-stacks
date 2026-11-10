# dsserver-stacks

Infrastructure configuration for **dsserver**, a home server: HP EliteDesk 800 G6 Mini running Debian 13 with KDE Plasma and Docker Engine.

- **Remote:** `git@github-stacks:dlsamu/dsserver-stacks.git` (private). The `github-stacks` SSH alias uses a deploy key that can only access this repository.
- **Local copy:** `/srv/stacks` (daniel:daniel 0750). Commit as daniel, **never with sudo**.
- **Commit identity:** set in this repository only, as Daniel Samuelsson `<ahdanielsamuelsson@gmail.com>`. No global identity is configured.
- **Host record:** [`host/docs/host-config.md`](host/docs/host-config.md) lists every change made to the host, with checks and rollback steps.
- **Rebuild from scratch:** [`RECOVERY.md`](RECOVERY.md).

## Layout
| Path | Purpose |
|---|---|
| `<service>/` | **One Compose project per service.** The directory name is the project name and the data directory name |
| `templates/service/` | Copy this to start a new service |
| `host/docs/` | Host configuration record |
| `docs/` | Planning: [roadmap](docs/roadmap.md), [monitoring architecture](docs/monitoring-architecture.md), [replacement NAS requirements](docs/nas-replacement-requirements.md) |
| `host/files/` | Copies of every host file we changed, laid out at their real paths |
| `host/scripts/` | The reviewed scripts used to configure the host, in order (`01-` … `10-`). Run 01–06 from a copy outside this directory; 07–10 read their files from this repository and write nothing into it, so they run in place |
| `host/bin/appdata-init` | Creates a service's data directories under `/srv/appdata` from its `appdata.dirs` |
| `host/bin/dsserver-health`, `host/bin/dsserver-reboot-needed` | Host heartbeat and reboot check (installed to `/usr/local/sbin` by scripts 07/08) |
| `host/tests/` | Unprivileged tests: `bash host/tests/test-dsserver-health.sh`, `bash host/tests/test-firewall.sh` (real traffic in a throw-away network namespace) |
| `docs/network-access.md` | How applications get network access: scopes localhost / LAN / VPN / internet, and the process |
| `.githooks/pre-commit` | Blocks commits of `.env`, `secrets/` and private keys (enabled with `core.hooksPath`) |

`/srv/appdata/<service>/` holds persistent container data. It is **not in Git**; it is covered by backups (backup phase). It is root:root 0700 at the top level, and each data directory is owned by the user ID the container runs as.

## Conventions for every service
1. **Pin images:** `name:<exact version>@sha256:<digest>`. Never use `latest`.
2. **`restart: unless-stopped`** and a **health check**: either the image's own, or a command that exists in the image.
3. **No secrets in Git.** Real values go in `<service>/.env` (0600) or `<service>/secrets/` (0700). Document every variable in `.env.example`.
4. **Data:** bind mounts under `/srv/appdata/<service>/` with `bind.create_host_path: false`. Create them with `sudo host/bin/appdata-init <service>`. Never create them by hand, and never let Docker create them.
5. **User ID:** run as a non-root uid:gid. Use the image's fixed user if it has one; otherwise take the next free ID from the registry below. Running as root needs a written reason in the service's README.
6. **Ports:** none unless needed. When needed, publish as `"${PUBLISH_ADDR:-127.0.0.1}:host:container"`. The address is set in that service's `.env`, never hard-coded, and defaults to localhost. LAN exposure waits for the firewall phase.
7. **Not allowed without a written reason:** `privileged`, `network_mode: host`, mounting the Docker socket, `cap_add`.
8. **Logging:** inherited from the daemon (`local` driver with rotation). No per-service override.
9. **No management tools** such as Portainer, Watchtower, Swarm or Kubernetes. Updates are done by hand (see below).

## User ID registry (2000–2999 is reserved for services)
Human accounts: daniel 1000, axel 1001. New human users must stay below 2000.

| uid:gid | Service | Why |
|---|---|---|
| — | — | (none yet) |

## Everyday commands (as daniel)
```bash
cd /srv/stacks/<service>
sudo docker compose config --quiet      # validate
sudo docker compose up -d               # create/start (also applies compose.yaml changes)
sudo docker compose ps                  # status + health
sudo docker compose logs -f --tail 100
sudo docker compose stop                # stays stopped across reboots
```

### Adding a service
1. `cp -r templates/service <name>`, then edit `compose.yaml`, `.env.example`, `appdata.dirs` and `README.md`. Pick the uid:gid and add it to the registry.
2. `cp <name>/.env.example <name>/.env && chmod 600 <name>/.env`, then fill in the real values.
3. `sudo host/bin/appdata-init <name>`
4. `cd <name> && sudo docker compose up -d`, then wait until `ps` shows healthy.
5. `git add <name> README.md && git commit` (the hook blocks secrets), then `git push`.

### Updating an image
Change the tag and digest, run `sudo docker compose pull && sudo docker compose up -d`, check it's healthy, then commit with the old → new version in the message.

## Development is kept separate
- Dev projects live in each user's home (`~/dev/<project>`), **never under `/srv`**.
- daniel's dev containers: `sudo docker compose -p dev-<project> …`, with `restart: "no"`, named volumes and no `/srv/appdata`.
- axel has no Docker access.
- **Never run** `docker system prune -a`, `docker volume prune` or `docker image prune -a` on this host. Clean up dev work with `sudo docker compose -p dev-<project> down -v`.
