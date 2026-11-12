# Cloudflare Tunnel (StockPulse, activation 2026-11-12)
Design, decisions, credentials needed, activation/rollback: [docs/external-access.md](../docs/external-access.md).
- `routes.toml`: the only list of public routes (StockPulse enabled).
- `cf.py`: Cloudflare API steps, run only by `host/scripts/16-tunnel.sh` (runbook and rollback: see the design doc).
- `python3 -I tunnel/render.py --check`: validate; `render.py --tunnel-id <uuid>`: print cloudflared `config.yml`.
- `cd tunnel && python3 -m unittest test_render`: 8 offline tests.
- `compose.yaml`: connector container (secrets in /etc/dsserver-secrets/cloudflared, never in Git).
