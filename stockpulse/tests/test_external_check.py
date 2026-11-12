"""Offline tests for stockpulse/external_check.py (SIMULATED: no network; dig/curl replaced by fakes).
    python3 -m unittest discover -s stockpulse/tests -p test_external_check.py
"""
import contextlib, io, json, os, subprocess, sys, tempfile, unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
import external_check as ec  # noqa: E402

LOGIN = "https://rubusdua.cloudflareaccess.com/cdn-cgi/access/login/stockpulse.rubusdua.net?redirect_url=%2Flatest%2Fus"


def fake(dns="104.21.93.198", health=(200, "cloudflare", "", "ok\n"), reports=(302, "cloudflare", LOGIN, "")):
    def resolve(host):
        return (dns, "1.1.1.1") if dns else (None, None)
    def curl(host, ip, path):
        return health if path == "/healthz" else reports
    return mock.patch.multiple(ec, resolve=resolve, curl=curl)


class Probe(unittest.TestCase):
    def check(self, expect_ok, needle, **kw):
        with fake(**kw):
            ok, reason = ec.probe(ec.HOST)
        self.assertEqual(ok, expect_ok, reason)
        self.assertIn(needle, reason)

    def test_healthy(self):                 self.check(True, "through Cloudflare")
    def test_no_dns(self):                  self.check(False, "dns: no answer", dns=None)
    def test_dns_rolled_back_to_lan(self):  self.check(False, "resolves publicly to 192.168.68.115", dns="192.168.68.115")
    def test_tunnel_down_530(self):         self.check(False, "tunnel down", health=(530, "cloudflare", "", "error"))
    def test_origin_down_502(self):         self.check(False, "origin (Caddy/app) not answering", health=(502, "cloudflare", "", ""))
    def test_no_https_answer(self):         self.check(False, "dsserver internet", health=(0, "", "", "TimeoutExpired"))
    def test_not_via_cloudflare(self):      self.check(False, "not Cloudflare", health=(200, "caddy", "", "ok"))
    def test_access_removed(self):          self.check(False, "PROTECTION", reports=(200, "cloudflare", "", "<html>report"))
    def test_redirect_elsewhere(self):      self.check(False, "PROTECTION", reports=(302, "cloudflare", "https://evil.example/x", ""))
    def test_access_name_in_path_only(self): self.check(False, "PROTECTION", reports=(302, "cloudflare", "https://evil.example/.cloudflareaccess.com/", ""))
    def test_http_login_refused(self):      self.check(False, "PROTECTION", reports=(302, "cloudflare", LOGIN.replace("https", "http", 1), ""))
    def test_lookalike_access_host(self):   self.check(False, "PROTECTION", reports=(302, "cloudflare", "https://cloudflareaccess.com.evil.example/", ""))


class Hysteresis(unittest.TestCase):
    """Sequences of probes through main(): exactly one ALARM and one CLEAR per incident."""
    def setUp(self):
        self.d = tempfile.mkdtemp()

    def run_main(self, *extra):
        out = io.StringIO()
        with mock.patch.object(sys, "argv", ["x", "--state", self.d, *extra]), contextlib.redirect_stdout(out):
            rc = ec.main()
        return rc, out.getvalue()

    def seq(self, results):
        return [self.run_main("--simulate", r)[0] for r in results]

    def alarm(self):
        return os.path.exists(os.path.join(self.d, "external-alarm"))

    def test_outage_one_alarm_one_recovery(self):
        rcs = self.seq(["ok", "fail", "fail", "fail", "fail", "fail", "ok", "ok", "ok"])
        self.assertEqual(rcs, [0, 0, 0, 10, 0, 0, 0, 11, 0])
        self.assertFalse(self.alarm())

    def test_two_failures_are_a_blip(self):
        self.assertEqual(self.seq(["fail", "fail", "ok", "fail", "fail", "ok"]), [0] * 6)
        self.assertFalse(self.alarm())

    def test_flapping_during_outage_does_not_recover_or_realert(self):
        rcs = self.seq(["fail"] * 3 + ["ok", "fail", "ok", "fail", "fail"] + ["ok", "ok"])
        self.assertEqual(rcs.count(10), 1); self.assertEqual(rcs.count(11), 1)
        self.assertEqual(rcs[3:8], [0] * 5)

    def test_alarm_state_survives_restart_of_the_check(self):
        self.seq(["fail"] * 3); self.assertTrue(self.alarm())
        self.assertEqual(self.seq(["fail"]), [0])                      # still alarmed, no second alert

    def test_history_is_bounded(self):
        self.seq(["ok"] * 30)
        with open(os.path.join(self.d, "external-history.json")) as f:
            self.assertEqual(len(json.load(f)), ec.KEEP)

    def test_corrupt_history_is_tolerated(self):
        with open(os.path.join(self.d, "external-history.json"), "w") as f:
            f.write("{broken")
        self.assertEqual(self.seq(["ok"]), [0])

    def test_test_flag_fails_probe_without_network(self):
        open(os.path.join(self.d, "external-fail-test"), "w").close()
        with mock.patch.object(ec, "probe", side_effect=AssertionError("must not probe")):
            rcs = [self.run_main()[0] for _ in range(3)]
        self.assertEqual(rcs, [0, 0, 10])

    def test_summary_is_actionable(self):
        with fake(health=(530, "cloudflare", "", "")):
            for _ in range(3):
                self.run_main()
        rc, out = self.run_main("--summary")
        self.assertEqual(rc, 0)
        self.assertIn("EXTERNAL ACCESS FAILED", out); self.assertIn("tunnel down", out); self.assertIn("16-tunnel.sh status", out)


class Curl(unittest.TestCase):
    def test_parses_code_server_redirect_body(self):
        r = subprocess.CompletedProcess([], 0, stdout="ok\n\n200 ", stderr="HTTP/2 200\r\nserver: cloudflare\r\n")
        with mock.patch.object(ec.subprocess, "run", return_value=r):
            self.assertEqual(ec.curl(ec.HOST, "1.2.3.4", "/healthz"), (200, "cloudflare", "", "ok\n"))

    def test_curl_pins_the_resolved_address_and_never_reuses_connections(self):
        r = subprocess.CompletedProcess([], 0, stdout="\n302 " + LOGIN, stderr="server: cloudflare\n")
        with mock.patch.object(ec.subprocess, "run", return_value=r) as run:
            code, _, redirect, _ = ec.curl(ec.HOST, "1.2.3.4", "/latest/us")
        self.assertEqual((code, redirect), (302, LOGIN))
        argv = run.call_args[0][0]
        self.assertIn(f"{ec.HOST}:443:1.2.3.4", argv); self.assertEqual(argv[0], "curl")

    def test_resolve_uses_public_resolvers_only(self):
        calls = []
        def run(argv, **kw):
            calls.append(argv[-1]); return subprocess.CompletedProcess(argv, 0, stdout="" if len(calls) == 1 else "104.21.93.198\n")
        with mock.patch.object(ec.subprocess, "run", side_effect=run):
            self.assertEqual(ec.resolve(ec.HOST), ("104.21.93.198", "9.9.9.9"))
        self.assertEqual(calls, ["@1.1.1.1", "@9.9.9.9"])


if __name__ == "__main__":
    unittest.main()
