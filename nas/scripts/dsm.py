"""DSM API client for dsnas. Usage as module: with DSM() as d: d.call(api, ver, method, **params). Never prints secrets."""
import json, ssl, os, urllib.request, urllib.parse
CRED = os.path.expanduser("~/.config/nas/dsnas-setup.cred")
class DSMError(Exception): pass
class DSM:
    def __init__(self, host="192.168.68.112", port=5001):
        self.url = f"https://{host}:{port}/webapi/entry.cgi"
        self.ctx = ssl.create_default_context(); self.ctx.check_hostname = False; self.ctx.verify_mode = ssl.CERT_NONE
        self.sid = None
    def _post(self, params, timeout=120):
        data = urllib.parse.urlencode(params).encode()
        hdr = {"X-SYNO-TOKEN": self.token} if getattr(self, "token", "") else {}
        with urllib.request.urlopen(urllib.request.Request(self.url, data=data, headers=hdr), context=self.ctx, timeout=timeout) as r:
            return json.load(r)
    def __enter__(self):
        c = dict(l.rstrip("\n").split("=", 1) for l in open(CRED) if "=" in l)
        r = self._post({"api": "SYNO.API.Auth", "version": "6", "method": "login", "account": c["username"],
                        "passwd": c["password"], "session": "claude-setup", "format": "sid", "enable_syno_token": "yes"})
        del c
        if not r.get("success"): raise DSMError(f"login failed code {r.get('error',{}).get('code')}")
        self.sid = r["data"]["sid"]; self.token = r["data"].get("synotoken", ""); return self
    def __exit__(self, *a):
        try: self._post({"api": "SYNO.API.Auth", "version": "6", "method": "logout", "session": "claude-setup", "_sid": self.sid})
        except Exception: pass
    def call(self, api, version, method, **params):
        p = {"api": api, "version": version, "method": method, "_sid": self.sid}
        for k, v in params.items(): p[k] = v if isinstance(v, str) else json.dumps(v)
        return self._post(p)
