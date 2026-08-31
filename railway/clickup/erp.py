"""Minimal ERPNext REST client over curl.

Python's SSL store is not configured on this machine (same constraint the Plane
provision script documents), so every request shells out to curl. Session-cookie
writes need an X-Frappe-CSRF-Token, which is lifted from the desk boot payload.
"""
import json, os, re, subprocess, tempfile, urllib.parse


class ERP:
    def __init__(self, base, user, pwd):
        self.base = base.rstrip("/")
        self.jar = tempfile.NamedTemporaryFile(prefix="erpjar", delete=False).name
        os.chmod(self.jar, 0o600)
        self.csrf = None
        self._login(user, pwd)

    def _curl(self, args):
        p = subprocess.run(["curl", "-sS", "-b", self.jar, "-c", self.jar] + args,
                           capture_output=True, text=True, timeout=120)
        if p.returncode:
            raise RuntimeError("curl failed: %s" % p.stderr[:300])
        return p.stdout

    def _login(self, user, pwd):
        # password goes in a 0600 file, never argv (argv is world-readable via ps)
        f = tempfile.NamedTemporaryFile("w", prefix="erplogin", suffix=".txt", delete=False)
        os.chmod(f.name, 0o600)
        f.write(urllib.parse.urlencode({"usr": user, "pwd": pwd}))
        f.close()
        try:
            out = self._curl(["-X", "POST", "--data", "@" + f.name,
                              self.base + "/api/method/login"])
        finally:
            os.unlink(f.name)
        if "Logged In" not in out:
            raise RuntimeError("login failed: %s" % out[:300])
        html = self._curl([self.base + "/app"])
        m = re.search(r'"csrf_token":\s*"([^"]+)"', html)
        self.csrf = m.group(1) if m else None

    def _json(self, method, path, body=None):
        args = ["-X", method, "-H", "Accept: application/json"]
        if self.csrf:
            args += ["-H", "X-Frappe-CSRF-Token: " + self.csrf]
        tmp = None
        if body is not None:
            tmp = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
            json.dump(body, tmp); tmp.close()
            args += ["-H", "Content-Type: application/json", "--data", "@" + tmp.name]
        try:
            out = self._curl(args + [self.base + path])
        finally:
            if tmp:
                os.unlink(tmp.name)
        try:
            return json.loads(out)
        except Exception:
            return {"_raw": out[:500]}

    def get(self, path):
        return self._json("GET", path)

    def post(self, path, body):
        return self._json("POST", path, body)

    def put(self, path, body):
        return self._json("PUT", path, body)

    def list(self, doctype, filters=None, fields=("name",), limit=200):
        q = urllib.parse.urlencode({"filters": json.dumps(filters or []),
                                    "fields": json.dumps(list(fields)),
                                    "limit_page_length": limit})
        d = self.get("/api/resource/%s?%s" % (urllib.parse.quote(doctype), q))
        return d.get("data", d)


DEFAULT_BASE = "https://erpnext-production-056b.up.railway.app"


def connect(base=None):
    """Admin password comes from railway/.env.local (gitignored) or ERPNEXT_ADMIN_PASSWORD."""
    pwd = os.environ.get("ERPNEXT_ADMIN_PASSWORD")
    if not pwd:
        env = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".env.local")
        pwd = [l.split("=", 1)[1].strip() for l in open(env)
               if l.startswith("ADMIN_PASSWORD=")][0]
    return ERP(base or os.environ.get("ERPNEXT_URL") or DEFAULT_BASE, "Administrator", pwd)
