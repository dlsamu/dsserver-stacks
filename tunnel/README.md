# Cloudflare Tunnel (template, NOT ACTIVE)
Design, decisions, credentials needed, activation/rollback: [docs/external-access.md](../docs/external-access.md).
- `routes.toml`: the only list of public routes (all `enabled = false` today).
- `python3 -I tunnel/render.py --check`: validate; `render.py --tunnel-id <uuid>`: print cloudflared `config.yml`.
- `cd tunnel && python3 -m unittest test_render`: 8 offline tests.
- `compose.yaml`: connector container (not started; no secrets exist yet).
