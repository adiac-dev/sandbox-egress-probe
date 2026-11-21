#!/usr/bin/env python3
"""One-shot probe for the invariant matrix. Runs as the pod's main container, prints ONE JSON line.

I2  startup window : from the first instant the container runs, hammer TCP to a public IP for RACE_SECONDS
                     and record whether / how long egress was open.
I3a direct DNS     : raw UDP DNS query straight to a public resolver.
I3b DNS forwarding : resolve a never-seen-before name under nip.io through the pod's resolver (kube-dns).
                     nip.io answers x<random>.1.2.3.4.nip.io with 1.2.3.4 — only possible if the label left the cluster.
nft status         : what the in-pod firewall init container reported (if the cell uses one).
"""
import json
import os
import random
import socket
import struct
import time

T0 = time.monotonic()
TARGET = (os.environ.get("RACE_TARGET_IP", "1.1.1.1"), int(os.environ.get("RACE_TARGET_PORT", "443")))
RACE_SECONDS = float(os.environ.get("RACE_SECONDS", "8"))
RESOLVER = os.environ.get("PUBLIC_RESOLVER", "8.8.8.8")


def ms():
    return round((time.monotonic() - T0) * 1000)


def tcp_open(addr, timeout=0.3):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect(addr)
        return True
    except OSError:
        return False
    finally:
        s.close()


def race():
    attempts, opens, first, last_open = 0, 0, None, None
    deadline = time.monotonic() + RACE_SECONDS
    while time.monotonic() < deadline:
        ok = tcp_open(TARGET)
        attempts += 1
        if first is None:
            first = ok
        if ok:
            opens += 1
            last_open = ms()
        time.sleep(0.05)
    return {"first_attempt_open": first, "open_attempts": opens, "attempts": attempts,
            "open_until_ms": last_open}   # None = never open


def dns_query(name: str) -> bytes:
    qid = random.randint(0, 65535)
    header = struct.pack(">HHHHHH", qid, 0x0100, 1, 0, 0, 0)
    q = b"".join(bytes([len(p)]) + p.encode() for p in name.split(".")) + b"\x00"
    return header + q + struct.pack(">HH", 1, 1)


def direct_dns_blocked():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(2)
    try:
        s.sendto(dns_query("example.com"), (RESOLVER, 53))
        s.recvfrom(512)
        return False
    except OSError:
        return True
    finally:
        s.close()


def cluster_dns_forwards():
    label = "x%08x" % random.getrandbits(32)
    name = f"{label}.1.2.3.4.nip.io"
    try:
        addrs = {a[4][0] for a in socket.getaddrinfo(name, 80, socket.AF_INET)}
        return "1.2.3.4" in addrs
    except OSError:
        return False


def nft_status():
    try:
        return open("/shared/nft-status").read().strip()
    except OSError:
        return None


if __name__ == "__main__":
    r = race()
    out = {
        "cell": os.environ.get("CELL"),
        "runtime": os.environ.get("RUNTIME"),
        "enforcement": os.environ.get("ENFORCEMENT"),
        "pod": os.environ.get("HOSTNAME"),
        "kernel": os.uname().release,          # gVisor reports its own fake kernel version — a sanity check
        "nft": nft_status(),
        "race_seconds": RACE_SECONDS,
        "i2": r,
        "i3a_direct_dns_blocked": direct_dns_blocked(),
        "i3b_cluster_dns_forwards": cluster_dns_forwards(),
    }
    print(json.dumps(out), flush=True)
