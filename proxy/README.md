# proxy — HTTPS front door on dsserver (Caddy)

Design and Cloudflare setup: [docs/https.md](../docs/https.md). Same image and certificate method as Beacon.

All commands go through the delegated script, which runs the reviewed snapshot (re-run
`sudo bash host/scripts/09-delegated-sudo.sh install <commit>` after committing changes here):

```
S=/usr/local/lib/dsserver-admin/host/scripts/14-https-proxy.sh
sudo -n $S preflight        # read-only
sudo -n $S token-install    # from ~/.cloudflare-token-dsserver (0600), checked, then shredded
sudo -n $S build            # image dsserver-caddy:2.11.9-cf0.2.4
sudo -n $S up               # (re)create container, wait for the certificate
sudo -n $S verify | status | token-check | down
```

Publishing an application: the app container joins the external network `proxy`
(`networks: {proxy: {external: true}}`), publishes no ports, and gets a block in `Caddyfile`
(`name.rubusdua.net { reverse_proxy <container>:<port> }`) plus an A record (DNS only) in Cloudflare.
Commit, `09 install`, `14 up`. LAN access needs 443/tcp in `lan_tcp` (docs/network-access.md) — once.
