"""mitmproxy addon = the L7 egress policy engine.
Allow: git clone/fetch from github.com. Deny: everything else, including git push.
Two enforcement points:
  1. http_connect — disallowed hosts are refused at CONNECT, before any upstream connection.
  2. request      — allowed hosts are inspected per method + path (after TLS interception)."""
import fnmatch
import logging

from mitmproxy import http

RULES = [
    {"host": "github.com", "methods": {"GET", "HEAD"}, "path": "*"},
    {"host": "github.com", "methods": {"POST"}, "path": "*/git-upload-pack"},
]
ALLOWED_HOSTS = {r["host"] for r in RULES}


def allowed(host, method, path, query):
    if "git-receive-pack" in path or "git-receive-pack" in query:  # push, on any method
        return False
    return any(
        host == r["host"] and method in r["methods"] and fnmatch.fnmatch(path, r["path"])
        for r in RULES
    )


def deny(flow, what):
    logging.warning(f"DENY  {what}")
    flow.response = http.Response.make(
        403, f"blocked by egress policy: {what}\n".encode(), {"Content-Type": "text/plain"}
    )


def http_connect(flow: http.HTTPFlow):
    host = flow.request.host
    if host not in ALLOWED_HOSTS:
        deny(flow, f"CONNECT {host}:{flow.request.port}")


def request(flow: http.HTTPFlow):
    req = flow.request
    path, _, query = req.path.partition("?")
    if allowed(req.pretty_host, req.method, path, query):
        logging.info(f"ALLOW {req.method} {req.pretty_host}{path}")
        return
    deny(flow, f"{req.method} {req.pretty_host}{path}")
