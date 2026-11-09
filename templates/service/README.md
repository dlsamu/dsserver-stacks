# example

**Purpose:** <what this service does and who uses it>

| Item | Value |
|---|---|
| Image | `docker.io/<org>/<image>:<version>@sha256:<digest>` (source: <URL of upstream project>) |
| Runs as | uid:gid `2001:2001`. Why: <image supports arbitrary UID / image's fixed user / documented root exception> |
| Data | `/srv/appdata/example/data` → `/data` (see `appdata.dirs`) |
| Ports | none (or: `${PUBLISH_ADDR}:<port>`, why it's needed) |
| Health check | <command, and what "healthy" means> |
| Secrets | in `.env` / `secrets/` (git-ignored); variables listed in `.env.example` |
| Backup notes | <consistent-backup needs, e.g. DB dump before backup, or "files only"> |
| Depends on | <other stacks or "nothing"> |

## Deploy
```bash
cd /srv/stacks/example
cp .env.example .env && chmod 600 .env && $EDITOR .env
sudo /srv/stacks/host/bin/appdata-init example
sudo docker compose config --quiet && sudo docker compose up -d
sudo docker compose ps          # wait for "healthy"
```

## Update
Change the tag and digest in `compose.yaml`, then
`sudo docker compose pull && sudo docker compose up -d`. Check that it's healthy, then commit.

## Notes
<anything unusual>
