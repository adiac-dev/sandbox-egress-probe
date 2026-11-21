# sandbox-egress-probe

**Verify, continuously and from inside the sandbox, that egress enforcement for AI-agent sandboxes actually holds — across the sandbox lifecycle and across runtimes.**

Egress controls for agent sandboxes (NetworkPolicy, L7 proxies, credential brokers, in-pod firewall sidecars) tend to fail *silently*: the policy object exists, the proxy reports healthy, the agent keeps working — and enforcement is gone. Teams running sandboxes in production are converging on the same answer: **treat enforcement as something you verify by evidence, not something you assume from configuration.**

This repo has two parts:

1. **A lab** that reproduces silent enforcement failures on a laptop (kind + NetworkPolicy + an L7 egress proxy).
2. **A probe** that runs next to the agent, keeps trying known bypass paths, and exports one verdict: `egress_enforcement_verified`.

The longer-term goal is an **implementation-agnostic set of invariants** — a conformance contract any enforcement implementation (NetworkPolicy, sidecar proxy, gateway, runtime-level firewall) can be checked against.

> Status: lab / early. Results so far are from kind on a laptop. Unverified means not verified — including claims in this README.

---

## Invariants

Every invariant below comes from a failure someone hit in the wild. The *Source* column links the evidence.

| # | Invariant | Why it exists | Source | Status |
|---|---|---|---|---|
| **I1** | **Default-deny holds.** Known bypass paths (direct IPv4/IPv6, cloud metadata, disallowed host via proxy) fail closed. | The baseline. Every other invariant assumes it. | — | ◐ implemented, needs control targets (see Finding 3) |
| **I2** | **No egress before enforcement is programmed.** The agent cannot reach the network in the window between pod start and the dataplane applying policy. | The policy object can exist before the CNI has programmed it. Agent code runs immediately, so the first seconds are the riskiest. | Finding 1; [agent-sandbox#1045](https://github.com/kubernetes-sigs/agent-sandbox/issues/1045) | ◐ observed, not yet gated |
| **I3** | **DNS is not a side channel.** (a) no direct queries to public resolvers; (b) cluster DNS does not forward arbitrary external names; (c) a wildcard allow rule does not forward guest-chosen labels upstream. | Default-deny policies rarely cover port 53 to kube-dns, and an allowed DNS path carries data out in the query name. | Finding 2; [agent-sandbox#1045](https://github.com/kubernetes-sigs/agent-sandbox/issues/1045); [OpenSandbox#2867](https://github.com/opensandbox-group/OpenSandbox/issues/2867) | ◐ (a)(b) implemented, (c) planned |
| **I4** | **Allowed hosts are allowed only for allowed operations.** e.g. `git clone` from GitHub works, `git push` does not. | Agents need broad domains (`github.com`, cloud APIs) but not every method and path on them. | [agent-sandbox#818](https://github.com/kubernetes-sigs/agent-sandbox/issues/818) (user story 1) | ● enforced by the lab proxy; allow-canary verifies the allowed side |
| **I5** | **Drift is detected while the sandbox runs.** A later change that opens egress (e.g. an additive "debug" NetworkPolicy) flips the verdict within one probe interval. | NetworkPolicies are additive. One "temporary" policy silently re-opens everything. | `demo.sh` | ● implemented |
| **I6** | **No evidence = not verified.** A stale or missing probe result counts as a failure, not as "probably fine". | A dead probe looks exactly like a healthy, quiet one. | — | ● implemented (staleness metric + alert) |
| **I7** | **The agent never holds the real credential.** The upstream sees the brokered credential; the agent process cannot read it. | Env-var secrets are readable by any code in the pod and leak via tool calls, prompts or outbound requests. | [agent-sandbox#1045](https://github.com/kubernetes-sigs/agent-sandbox/issues/1045); [agent-sandbox#1580](https://github.com/kubernetes-sigs/agent-sandbox/issues/1580) | ○ planned |
| **I8** | **Teardown revokes before it stops.** After delete is requested, credentials are revoked and egress is denied *before* the workload stops; no survivors remain (netns, rules, vault entries). | Stopping the workload first leaves credentials and allow rules live during the grace period; a process that ignores SIGTERM keeps using them. | [OpenSandbox#2866](https://github.com/opensandbox-group/OpenSandbox/issues/2866) | ○ planned |
| **I9** | **Same policy, same result, on every runtime.** I1–I8 give the same verdict under runc, gVisor (runsc) and Kata. | Where enforcement lives matters: in-sandbox rules (e.g. an nftables sidecar) are interpreted by the runtime's network stack; host-side rules are not. Reports exist of rules that work under runc/Kata and fail or do not apply under gVisor. | [gvisor#7469](https://github.com/google/gvisor/issues/7469); [gvisor#13796](https://github.com/google/gvisor/issues/13796) | ○ planned |

Legend: ● implemented · ◐ partial · ○ planned

### Conformance matrix (target)

The goal is to fill this table with measured results, not opinions. Empty cells have not been run.

| Invariant | runc + host-side NetworkPolicy | runc + in-pod sidecar | runsc + host-side NetworkPolicy | runsc + in-pod sidecar |
|---|---|---|---|---|
| I1 default-deny | ✅ ipv4 + external resolver (kind); ipv6/metadata inconclusive, see Finding 3 | | | |
| I2 startup window | ❌ 3/3 fresh pods open on first run (kind/kindnet) | | | |
| I3b DNS via cluster DNS | ❌ open (kind) | | | |
| I5 drift detection | ✅ (kind) | | | |

---

## What's in the lab

| Component | Role |
|---|---|
| `kind.yaml` | Local kind cluster. |
| `00-namespaces.yaml` | Namespaces for the lab. |
| `10-netpol.yaml` | Default-deny egress for the `sandbox` namespace. Only kube-dns and the egress proxy are reachable. |
| `20-proxy.yaml` + `policy.py` | mitmproxy as an L7 egress proxy. Disallowed hosts are refused at CONNECT. Allowed hosts are filtered by method and path (`git clone` allowed, `git push` not). |
| `30-client.yaml` | The "agent" container, plus a probe sidecar in the same network namespace. |
| `probe.py` + `Dockerfile` | Every 15 seconds: tries known bypass paths, runs an allow-canary, exports Prometheus metrics on `:9100/metrics`. |
| `99-debug-allow-all.yaml` | The "temporary debug policy" used by the silent-failure demo. |
| `setup.sh` / `test.sh` / `demo.sh` | Build the lab, run the functional checks, run the silent-failure demo. |

## Quick start

Requires Docker (e.g. Colima), `kind` and `kubectl`.

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
| `external_dns_resolver` | DNS query directly to a public resolver |
| `proxy_disallowed_host` | A disallowed host via the proxy must get `403` at CONNECT |

**Allow-canary:** an allowed request must succeed through the proxy. A probe that only proves things are blocked can't tell enforcement from an outage.

**Verdict:** `egress_enforcement_verified` is `1` only if the canary passes **and** every deny check holds.

**DNS exfiltration** is reported separately as `egress_dns_exfil_blocked`: a unique name under an external domain is resolved through cluster DNS. An upstream answer means data can leave via DNS.

### Metrics

| Metric | Meaning |
|---|---|
| `egress_bypass_blocked{path}` | 1 = blocked, 0 = bypass succeeded |
| `egress_allow_canary_ok` | 1 = allowed traffic works through the proxy |
| `egress_enforcement_verified` | 1 = canary ok **and** all deny checks hold |
| `egress_dns_exfil_blocked` | 1 = cluster DNS does not forward external names |
| `egress_proxy_up` | 1 = proxy responded |
| `egress_probe_last_run_timestamp_seconds` | for staleness alerting |

### Suggested alerts

```yaml
- alert: EgressEnforcementNotVerified
  expr: egress_enforcement_verified == 0
  for: 1m
- alert: EgressProbeStale            # absence of evidence = unverified (I6)
  expr: time() - egress_probe_last_run_timestamp_seconds > 60
```

## Demo result

`demo.sh` applies a debug policy (`99-debug-allow-all.yaml`). NetworkPolicies are additive, so it opens all egress. The agent's `git clone` still works and nothing looks wrong — but the probe reports:

- **Baseline:** `direct_ipv4` and `external_dns_resolver` blocked, `egress_enforcement_verified = 1`
- **After the debug policy:** both bypass checks read `0`, `egress_enforcement_verified = 0`

## Findings so far

1. **New sandboxes start with open egress (I2).** On 3 of 3 fresh pods, the first probe run found direct egress open; the next run, seconds later, found it blocked. This matches Kubernetes behavior — a pod can start before the network plugin applies its NetworkPolicy. For agent sandboxes this window is the riskiest, since agent code runs immediately. Measured on kind/kindnet; other CNIs will differ.
2. **DNS exfiltration is open (I3b).** `egress_dns_exfil_blocked` was `0` on every run. Allowing kube-dns — which the proxy's service name requires — also forwards arbitrary external names upstream. Default-deny NetworkPolicy alone does not close this path.
3. **A failed connection is not proof of a block (I1).** kind has no metadata service and no IPv6 route, so `cloud_metadata` and `direct_ipv6` read "blocked" even with allow-all. Every deny check needs a **control**: proof that the target is reachable from outside the sandbox, so "blocked" means blocked and not "unreachable anyway".

## Roadmap

Ordered by cost to run in the lab:

- [ ] **Control targets for deny checks** (I1) — a deny check only counts when its control passes.
- [ ] **Gate agent start on verification** (I2) — hold the agent *process* until the first `verified=1`, not just container start order. (A native-sidecar `startupProbe` gates container start, which is not the same thing per task.)
- [ ] **Runtime matrix** (I9) — run the same suite under runsc and Kata; compare host-side NetworkPolicy with an in-pod nftables sidecar.
- [ ] **Wildcard DNS label leak** (I3c) — reproduce the OpenSandbox#2867 case.
- [ ] **Brokered-identity canary** (I7) — confirm the upstream sees the brokered credential and the agent cannot read the real one.
- [ ] **Teardown checks** (I8) — verify revoke → deny → stop ordering and a post-teardown survivor check.
- [ ] Run against `kubernetes-sigs/agent-sandbox` `Sandbox` resources instead of plain Pods.
- [ ] Surface the verdict as a per-sandbox status condition (`EnforcementVerified` + last-verified timestamp). See the upstream proposal linked from [agent-sandbox#1045](https://github.com/kubernetes-sigs/agent-sandbox/issues/1045).
- [ ] Turn I1–I9 into a conformance contract that enforcement implementations can run against.

## Contributing invariants

If you run sandboxes in production and enforcement failed in a way this list doesn't cover, open an issue with:

1. the invariant, stated as something that must always hold,
2. how it broke (runtime, CNI or enforcement mechanism, lifecycle phase),
3. how you detect it today — if you do.

Failure modes from real fleets are worth more than ideas. Invariants without evidence stay out of the table.

## Security notes

`ca/` holds the lab CA private key and is git-ignored. This is a lab: do not reuse that CA anywhere else.

## License

Apache-2.0. See `LICENSE`. This project follows a Code of Conduct.
