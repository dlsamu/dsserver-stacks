"""Offline tests for render.py:  cd tunnel && python3 -m unittest test_render"""
import unittest

import render as r

SITES = {"stockpulse.rubusdua.net", "dsserver.rubusdua.net", "train.rubusdua.net"}
OK = {"hostname": "stockpulse.rubusdua.net", "enabled": True, "access": "otp", "allowed_emails": ["a@b"],
      "health_path": "/healthz", "bypass_paths": ["/healthz"]}


class Render(unittest.TestCase):
    def test_valid(self):
        self.assertEqual(r.problems([OK], SITES), [])

    def test_infrastructure_names_refused(self):
        for h in ("beacon.rubusdua.net", "dsserver.rubusdua.net", "ssh.rubusdua.net", "admin.rubusdua.net"):
            self.assertTrue(any("infrastructure" in p for p in r.problems([dict(OK, hostname=h)], SITES | {h})), h)

    def test_other_zone_and_nesting_refused(self):
        self.assertTrue(r.problems([dict(OK, hostname="stockpulse.example.com")], SITES))
        self.assertTrue(r.problems([dict(OK, hostname="a.b.rubusdua.net")], SITES))

    def test_must_go_through_caddy(self):
        self.assertTrue(r.problems([dict(OK, service="http://stockpulse-web:8080")], SITES))
        self.assertTrue(any("Caddy site" in p for p in r.problems([dict(OK, hostname="new.rubusdua.net")], SITES)))

    def test_access_rules(self):
        self.assertTrue(r.problems([dict(OK, access="none")], SITES))
        self.assertTrue(r.problems([dict(OK, allowed_emails=[])], SITES))
        self.assertTrue(r.problems([dict(OK, access="public")], SITES))
        self.assertEqual(r.problems([dict(OK, access="public", public_reason="x")], SITES), [])
        self.assertTrue(r.problems([dict(OK, bypass_paths=["/"])], SITES))

    def test_duplicates(self):
        self.assertTrue(any("duplicate" in p for p in r.problems([OK, OK], SITES)))

    def test_render_only_enabled_and_default_404(self):
        cfg = r.render([OK, dict(OK, hostname="train.rubusdua.net", enabled=False)], "00000000-0000-4000-8000-000000000000")
        self.assertIn("hostname: stockpulse.rubusdua.net", cfg)
        self.assertNotIn("train.rubusdua.net", cfg)
        self.assertTrue(cfg.rstrip().endswith("- service: http_status:404"))
        self.assertIn("originServerName: stockpulse.rubusdua.net", cfg)

    def test_caddy_sites_parsed_from_repo(self):
        from pathlib import Path
        sites = r.caddy_sites(Path(__file__).resolve().parent.parent / "proxy" / "Caddyfile")
        self.assertIn("stockpulse.rubusdua.net", sites)


if __name__ == "__main__":
    unittest.main()
