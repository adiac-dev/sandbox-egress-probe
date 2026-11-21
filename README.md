# sandbox-egress-probe

**Verify that egress enforcement for AI-agent sandboxes is actually working — continuously, from inside the sandbox.**

Egress controls for agent sandboxes (NetworkPolicy, L7 proxies, credential brokers) usually fail *silently*: the policy is configured, the proxy reports healthy, the agent keeps working — and the enforcement is gone. This lab reproduces that failure mode on a laptop and shows a probe that catches it.

## What's in the lab

| Component | Role |
|---|---|
| `10-netpol.yaml` | Default-deny egress for the `sandbox` namespace; only kube-dns and the egress proxy are reachable |
| `20-proxy.yaml` + `policy.py` | mitmproxy as an L7 egress proxy. Disallowed hosts are refused at `CONNECT`; allowed hosts are filtered by method + path (`git clone` yes, `git push` no) |
| `30-client.yaml` | The "agent" container, plus a **probe sidecar** in the same network namespace |
| `probe.py` | Every 15s: attempts known bypass paths, runs an allow-canary, exports Prometheus metrics on `:9100/metrics` |
| `demo.sh` | Silent-failure demo: a "temporary" debug NetworkPolicy opens egress; the agent notices nothing; the probe does |

## Quick start

Requires Docker (e.g. Colima), `kind`, `kubectl`.

```bash
./setup.sh   # kind cluster, lab CA, proxy, policies, client + probe
./test.sh    # 4 functional checks
./demo.sh    # silent-failure demo
```

## The probe

**Deny checks** — each must fail closed:

| Path | Attempt |
|---|---|
| `direct_ipv4` | TCP to a public IP, ignoring `HTTPS_PROXY` |
| `direct_ipv6` | TCP to a public IPv6 address |
| `cloud_metadata` | TCP to `169.254.169.254` |
| `external_dns_resolver` | DNS query straight to a public resolver |
| `proxy_disallowed_host` | A disallowed host through the proxy must get `403` at `CONNECT` |

**Allow-canary** — an allowed request must *succeed* through the proxy. A deny-only probe passes trivially when nothing works at all, so `egress_enforcement_verified` is `1` only if the canary passes **and** every deny check holds. Unverified means not verified.

**DNS exfiltration** — reported separately (`egress_dns_exfil_blocked`): a unique name under an external domain is resolved through cluster DNS; if it gets an upstream answer, data can leave via DNS.

### Metrics

```
egress_bypass_blocked{path="..."}            1 = blocked, 0 = bypass succeeded
egress_allow_canary_ok                       1 = allowed traffic works through the proxy
egress_enforcement_verified                  1 = canary ok AND all deny checks hold
egress_dns_exfil_blocked                     1 = cluster DNS does not forward external names
egress_proxy_up                              1 = proxy answered
egress_probe_last_run_timestamp_seconds      staleness must alert too
```

Suggested alerts:

```yaml
- alert: EgressEnforcementUnverified
  expr: egress_enforcement_verified == 0
  for: 1m
- alert: EgressProbeStale        # absence of evidence = unverified
  expr: time() - egress_probe_last_run_timestamp_seconds > 60
```

## Demo result

A debug policy (`99-debug-allow-all.yaml`) is applied. NetworkPolicies are additive, so it opens all egress. The agent's `git clone` keeps working; nothing looks wrong — except the probe:

```
== 1. baseline
egress_bypass_blocked{path="direct_ipv4"} 1
egress_bypass_blocked{path="external_dns_resolver"} 1
egress_enforcement_verified 1

== 3. the agent still works — nothing looks wrong
  git clone: ok

== 4. but the probe sees the gap
egress_bypass_blocked{path="direct_ipv4"} 0
egress_bypass_blocked{path="external_dns_resolver"} 0
egress_enforcement_verified 0
```

## Findings so far

1. **Every new sandbox starts with open egress.** On 3 out of 3 fresh pods, the probe's first run (right after container start) found direct egress open (`verified=0 direct_ipv4=OPEN`); the next run, seconds later, found it blocked. This matches documented Kubernetes behavior: a pod may start unprotected, and isolation applies only once the network plugin has processed the NetworkPolicy. For agent sandboxes this is the worst possible window: a fresh pod per task, and the agent executes code immediately. Measured here on kind/kindnet; the window will differ per CNI, which is exactly why it has to be measured rather than assumed.

   Reproduce:
   ```bash
   for i in 1 2 3; do
     kubectl -n sandbox delete pod client --wait=true >/dev/null
     sed 's/value: "15"/value: "2"/' 30-client.yaml | kubectl apply -f - >/dev/null
     kubectl -n sandbox wait pod/client --for=condition=Ready --timeout=120s >/dev/null
     sleep 12
     echo "== run $i"; kubectl -n sandbox logs client -c probe | head -3
   done
   ```

2. **DNS exfiltration is open in this setup.** `egress_dns_exfil_blocked` was `0` on every run: allowing kube-dns (needed for the proxy's service name) also forwards arbitrary external names upstream. Default-deny NetworkPolicy alone does not close this path.
3. **A failed connection is not proof of a block.** In kind there is no metadata service and no IPv6 route, so `cloud_metadata` and `direct_ipv6` report "blocked" even with an allow-all policy. That is false assurance. Each deny check needs a control: proof that the target is reachable from outside the sandbox.

## Roadmap

- [ ] Gate agent start on verification: run the probe as a native sidecar (restartable init container) whose `startupProbe` passes only once `verified=1`, so the agent container cannot start inside the unprotected window
- [ ] Control targets for deny checks (reachable-from-outside verification)
- [ ] Brokered-identity canary: assert the upstream saw the brokered credential, not the agent's
- [ ] Run against `kubernetes-sigs/agent-sandbox` `Sandbox` resources, not plain Pods
- [ ] Surface the result as a per-sandbox status condition (e.g. `EnforcementVerified` + last-verified timestamp)
- [ ] Probe suite as a conformance contract that any enforcement implementation can be tested against

## Security notes

`ca/` holds the lab CA private key and is git-ignored. This is a lab — do not reuse the CA anywhere else.
