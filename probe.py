"""Egress enforcement probe — runs as a sidecar in the sandbox pod (same network namespace).
Every PROBE_INTERVAL seconds it attempts known bypass paths and exposes the results as
Prometheus metrics on :9100/metrics. 1 = bypass blocked (good), 0 = bypass succeeded (gap)."""
import os
import socket
import subprocess
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, HTTPServer

PROXY = os.environ.get("PROBE_PROXY", "http://egress-proxy.egress.svc.cluster.local:8080")
CA = os.environ.get("PROBE_CA", "/ca/ca.crt")
INTERVAL = int(os.environ.get("PROBE_INTERVAL", "15"))
PORT = int(os.environ.get("PROBE_PORT", "9100"))

state = {"results": {}, "dns_exfil_blocked": None, "proxy_up": None, "last_run": 0.0}
lock = threading.Lock()


def run(cmd, timeout=8):
    try:
        p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
        return p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        return 124, "timeout"


def tcp_blocked(host, port, family=socket.AF_INET):
    try:
        with socket.socket(family, socket.SOCK_STREAM) as s:
            s.settimeout(3)
            s.connect((host, port))
        return False
    except OSError:
        return True


def external_dns_blocked():
    # Query a public resolver directly, bypassing cluster DNS
    rc, _ = run(["dig", "@8.8.8.8", "example.com", "+time=2", "+tries=1", "+short"])
    return rc != 0


def proxy_check():
    # Through the proxy, a disallowed host must be refused at CONNECT (403)
    rc, out = run(["curl", "-s", "-o", "/dev/null", "-w", "%{http_connect}",
                   "--max-time", "5", "--proxy", PROXY, "--cacert", CA, "https://example.com"])
    code = out.strip()[-3:]
    return code != "000", code == "403"  # (proxy reachable, disallowed host refused)


def dns_exfil_blocked():
    # A unique name under an external domain: if cluster DNS forwards it upstream, data can leave via DNS
    name = f"{uuid.uuid4().hex[:12]}.egress-probe.example.com."
    rc, out = run(["dig", name, "+time=2", "+tries=1"])
    leaked = "status: NXDOMAIN" in out or "status: NOERROR" in out
    return not leaked


CHECKS = {
    "direct_ipv4": lambda: tcp_blocked("1.1.1.1", 443),
    "direct_ipv6": lambda: tcp_blocked("2606:4700:4700::1111", 443, socket.AF_INET6),
    "cloud_metadata": lambda: tcp_blocked("169.254.169.254", 80),
    "external_dns_resolver": external_dns_blocked,
}


def probe_once():
    results = {name: fn() for name, fn in CHECKS.items()}
    proxy_up, proxy_refuses = proxy_check()
    results["proxy_disallowed_host"] = proxy_refuses
    exfil = dns_exfil_blocked()
    with lock:
        state.update(results=results, dns_exfil_blocked=exfil, proxy_up=proxy_up, last_run=time.time())
    verified = all(results.values())
    summary = " ".join(f"{k}={'blocked' if v else 'OPEN'}" for k, v in results.items())
    print(f"verified={int(verified)} proxy_up={int(proxy_up)} dns_exfil={'blocked' if exfil else 'OPEN'} {summary}",
          flush=True)


def loop():
    while True:
        try:
            probe_once()
        except Exception as e:  # never let the probe die silently
            print(f"probe error: {e}", flush=True)
        time.sleep(INTERVAL)


def render():
    with lock:
        s = dict(state)
    lines = [
        "# HELP egress_bypass_blocked 1 if the bypass attempt was blocked, 0 if it succeeded",
        "# TYPE egress_bypass_blocked gauge",
    ]
    for path, ok in s["results"].items():
        lines.append(f'egress_bypass_blocked{{path="{path}"}} {int(ok)}')
    if s["results"]:
        lines += [
            "# HELP egress_enforcement_verified 1 if every in-scope bypass path is blocked",
            "# TYPE egress_enforcement_verified gauge",
            f"egress_enforcement_verified {int(all(s['results'].values()))}",
            "# HELP egress_dns_exfil_blocked 1 if cluster DNS does not forward external names (DNS exfiltration)",
            "# TYPE egress_dns_exfil_blocked gauge",
            f"egress_dns_exfil_blocked {int(s['dns_exfil_blocked'])}",
            "# HELP egress_proxy_up 1 if the egress proxy answered",
            "# TYPE egress_proxy_up gauge",
            f"egress_proxy_up {int(s['proxy_up'])}",
        ]
    lines += [
        "# HELP egress_probe_last_run_timestamp_seconds Unix time of the last completed probe run",
        "# TYPE egress_probe_last_run_timestamp_seconds gauge",
        f"egress_probe_last_run_timestamp_seconds {s['last_run']:.0f}",
    ]
    return "\n".join(lines) + "\n"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        body = render().encode() if self.path == "/metrics" else b"ok\n"
        self.send_response(200)
        self.send_header("Content-Type", "text/plain; version=0.0.4")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    threading.Thread(target=loop, daemon=True).start()
    HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
