"""Offline tests for netwatch.py (no hub, no network):  python3 -m unittest -v test_netwatch   (in beacon/netwatch)"""
import os, sqlite3, tempfile, unittest

os.environ["NETWATCH_DB"] = os.path.join(tempfile.mkdtemp(), "t.db")
import netwatch as nw  # noqa: E402

MIN = nw.MIN
MONS = [  # id, protocol, target, port, server, interval
    ("g", "icmp", "192.168.68.1", 0, "", 60), ("cf", "icmp", "1.1.1.1", 0, "", 60), ("q9", "icmp", "9.9.9.9", 0, "", 60),
    ("dl", "dns", "deb.debian.org", 0, "192.168.68.1", 300), ("dp", "dns", "deb.debian.org", 0, "9.9.9.9", 60),
    ("hd", "http", "https://deb.debian.org/", 0, "", 300), ("hg", "http", "https://www.google.com/generate_204", 0, "", 300),
    ("di", "icmp", "192.168.68.115", 0, "", 60), ("dt", "tcp", "192.168.68.115", 443, "", 60),
    ("sp", "http", "https://stockpulse.rubusdua.net/healthz", 0, "", 60),
]
T0 = 1_800_000_000_000 // MIN * MIN


class Netwatch(unittest.TestCase):
    def setUp(self):
        if os.path.exists(nw.DB):
            os.remove(nw.DB)
        self.c = nw.db()
        for i, p, t, port, srv, iv in MONS:
            m = {"protocol": p, "target": t, "port": port, "server": srv}
            self.c.execute("insert into monitor values(?,?,?,?,?,?,?,?,?)", (i, nw.role_of(m), p, t, port, srv, iv, 1, 0))
        self.c.commit()

    def tearDown(self):
        self.c.close()

    def fill(self, minutes, fail=lambda mon, k: False, skip=lambda k: False):
        for k in range(minutes):
            if skip(k):
                continue
            for i, *_r, iv in MONS:
                if k % (iv // 60) == 0:
                    bad = fail(i, k)
                    self.c.execute("insert into minute values(?,?,?,?,?)", (i, T0 + k * MIN, 0 if bad else 1, 1, 1000))
        self.c.commit()

    def inc(self, minutes=60):
        return [(i["cls"], (i["start"] - T0) // MIN, (i["end"] - T0) // MIN) for i in nw.incidents(self.c, T0, T0 + minutes * MIN)]

    def test_roles(self):
        roles = {r for (r,) in self.c.execute("select role from monitor")}
        self.assertEqual(roles, {"gateway", "wan_cf", "wan_q9", "dns_local", "dns_public", "https_debian", "https_google",
                                 "dsserver_icmp", "dsserver_tcp", "stockpulse"})

    def test_all_ok(self):
        self.fill(60)
        self.assertEqual(self.inc(), [])

    def test_wan_outage_with_dns_and_https_failing_is_wan(self):
        wan = {"cf", "q9", "dl", "dp", "hd", "hg"}
        self.fill(60, fail=lambda m, k: 10 <= k < 25 and m in wan)
        self.assertEqual(self.inc(), [("internet (WAN)", 10, 24)])

    def test_gateway_wins(self):
        self.fill(60, fail=lambda m, k: 30 <= k < 33 and m not in {"di", "dt", "sp"})
        self.assertEqual(self.inc()[0][0], "LAN/gateway")

    def test_deco_dns_only(self):  # 5-minute DNS check: one failed sample covers 5 minutes
        self.fill(60, fail=lambda m, k: k == 20 and m == "dl")
        self.assertEqual(self.inc(), [("Deco DNS", 20, 24)])

    def test_single_path(self):
        self.fill(60, fail=lambda m, k: 5 <= k < 8 and m == "cf")
        self.assertEqual(self.inc(), [("single WAN path", 5, 7)])

    def test_dsserver_https_vs_down(self):
        self.fill(60, fail=lambda m, k: (10 <= k < 13 and m == "dt") or (40 <= k < 45 and m in {"di", "dt", "sp"}))
        self.assertEqual(self.inc(), [("dsserver HTTPS", 10, 12), ("dsserver down", 40, 44)])

    def test_stockpulse_only(self):
        self.fill(60, fail=lambda m, k: 50 <= k < 52 and m == "sp")
        self.assertEqual(self.inc(), [("StockPulse web", 50, 51)])

    def test_no_data_gap(self):
        self.fill(60, skip=lambda k: 30 <= k < 40)
        cls = self.inc()
        self.assertEqual(cls[0][0], "no data")
        self.assertEqual(cls[0][1], 30)

    def test_short_gap_merged(self):
        self.fill(60, fail=lambda m, k: k in (10, 11, 13, 14) and m in {"cf", "q9"})
        self.assertEqual(self.inc(), [("internet (WAN)", 10, 14)])


if __name__ == "__main__":
    unittest.main()
