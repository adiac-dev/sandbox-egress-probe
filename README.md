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
| **I2** | **No egress before enforcement is programmed.** The agent cannot reach the network in the window between pod start and the dataplane applying policy. | The policy object can exist before the CNI has programmed it. Agent code runs immediately, so the first moments are the riskiest. | Finding 1; [agent-sandbox#1045](https://github.com/kubernetes-sigs/agent-sandbox/issues/1045) | ◐ measured (`experiments/`), not yet gated |
| **I3** | **DNS is not a side channel.** (a) no direct queries to public resolvers; (b) cluster DNS does not forward arbitrary external names; (c) a wildcard allow rule does not forward guest-chosen labels upstream. | Default-deny policies rarely cover port 53 to kube-dns, and an allowed DNS path carries data out in the query name. | Finding 2; [agent-sandbox#1045](https://github.com/kubernetes-sigs/agent-sandbox/issues/1045); [OpenSandbox#2867](https://github.com/opensandbox-group/OpenSandbox/issues/2867) | ◐ (a)(b) implemented and measured, (c) planned |
| **I4** | **Allowed hosts are allowed only for allowed operations.** e.g. `git clone` from GitHub works, `git push` does not. | Agents need broad domains (`github.com`, cloud APIs) but not every method and path on them. | [agent-sandbox#818](https://github.com/kubernetes-sigs/agent-sandbox/issues/818) (user story 1) | ● enforced by the lab proxy; allow-canary verifies the allowed side |
| **I5** | **Drift is detected while the sandbox runs.** A later change that opens egress (e.g. an additive "debug" NetworkPolicy) flips the verdict within one probe interval. | NetworkPolicies are additive. One "temporary" policy silently re-opens everything. | `demo.sh` | ● implemented |
| **I6** | **No evidence = not verified.** A stale or missing probe result counts as a failure, not as "probably fine". | A dead probe looks exactly like a healthy, quiet one. | — | ● implemented (staleness metric + alert) |
| **I7** | **The agent never holds the real credential.** The upstream sees the brokered credential; the agent process cannot read it. | Env-var secrets are readable by any code in the pod and leak via tool calls, prompts or outbound requests. | [agent-sandbox#1045](https://github.com/kubernetes-sigs/agent-sandbox/issues/1045); [agent-sandbox#1580](https://github.com/kubernetes-sigs/agent-sandbox/issues/1580) | ○ planned |
| **I8** | **Teardown revokes before it stops.** After delete is requested, credentials are revoked and egress is denied *before* the workload stops; no survivors remain (netns, rules, vault entries). | Stopping the workload first leaves credentials and allow rules live during the grace period; a process that ignores SIGTERM keeps using them. | [OpenSandbox#2866](https://github.com/opensandbox-group/OpenSandbox/issues/2866) | ○ planned |
| **I9** | **Same policy, same result, on every runtime.** I1–I8 give the same verdict under runc, gVisor (runsc) and Kata. | Where enforcement lives matters: in-sandbox rules (e.g. an nftables sidecar) are interpreted by the runtime's network stack; host-side rules are not. Reports exist of rules that work under runc/Kata and fail or do not apply under gVisor. | [gvisor#7469](https://github.com/google/gvisor/issues/7469); [gvisor#13796](https://github.com/google/gvisor/issues/13796) | ◐ runc vs gVisor measured for I1–I3 (`experiments/`); Kata not yet |

Legend: ● implemented · ◐ partial · ○ planned

### Conformance matrix

Measured with [`experiments/`](experiments/): 10 fresh pods per cell, kind/kindnet on a laptop (Colima, arm64),
gVisor `release-20261116.0` in its default configuration. Control cells (no enforcement) were open 10/10 under
both runtimes, so every "blocked" below is a real block.

| Invariant | runc + host-side NetworkPolicy | runc + in-pod nftables | gVisor + host-side NetworkPolicy | gVisor + in-pod nftables |
|---|---|---|---|---|
| I1 default-deny (direct TCP, 10/10 pods) | ✅ after start-up | ✅ | ✅ after start-up | ❌ rules not installable — agent had full egress |
| I2 no egress at start | ❌ 10/10 open at start; median 386 ms, max 556 ms | ✅ 0/10 | ❌ 10/10 open at start; median 324 ms, max 331 ms | ❌ never closed |
| I3a no direct public DNS | ✅ 10/10 | ✅ 10/10 | ✅ 10/10 | ❌ 0/10 |
| I3b cluster DNS doesn't forward external names | ❌ 10/10 forwarded | ❌ 10/10 forwarded | ❌ 10/10 forwarded | ❌ 10/10 forwarded |
| I5 drift detected | ✅ (`demo.sh`) | | | |

**No configuration satisfies I2, I3 and I9 together.** Host-side enforcement behaves the same on both runtimes
but leaves a start-up window. In-pod enforcement closes the window but depends on the runtime: it works under runc
and can't be installed under gVisor's default configuration. DNS forwarding is open everywhere.

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

1. **New sandboxes start with open egress under host-side enforcement (I2).** 10 of 10 fresh pods could reach the
   internet on their first attempt, under both runc (median 386 ms, max 556 ms) and gVisor (median 324 ms,
   max 331 ms). That's the gap between the pod starting and the CNI programming its NetworkPolicy. The numbers are a
   lower bound: the probe starts measuring only after its interpreter is up. In-pod rules installed by an init
   container had no window (0/10), because they're in place before the agent starts. Measured on kind/kindnet; other
   CNIs will differ.
2. **DNS exfiltration is open in every enforced configuration (I3b).** A never-seen name under an external zone
   resolved 40 of 40 times, across both runtimes and both enforcement locations. Every configuration has to allow
   kube-dns, and kube-dns forwards whatever it doesn't know. Default-deny, wherever it lives, doesn't close this path.
3. **A failed connection is not proof of a block (I1).** kind has no metadata service and no IPv6 route, so
   `cloud_metadata` and `direct_ipv6` read "blocked" even with allow-all. Every deny check needs a **control**: proof
   that the target is reachable without enforcement. `experiments/` runs a control cell per runtime for this reason.
4. **In-pod nftables can't be installed under gVisor's default configuration (I9).** `nft` failed with
   `mnl.c:61: Unable to initialize Netlink socket` on 10 of 10 pods. In `runsc` (`release-20261116.0`), nftables
   support in the sandbox kernel exists only behind a flag marked `TEST ONLY` (`-TESTONLY-nftables`). So the one
   configuration with no start-up window isn't available under gVisor. What happens next is decided by the
   enforcement component, not by the policy: the lab's init container logs the error and continues, and the agent
   then had full egress for the whole run, including direct public DNS (10/10). A strict component would block the
   pod from starting instead. Nothing in the policy configuration tells you which of the two you have.
   Related: [gvisor#13796](https://github.com/google/gvisor/issues/13796).

## Roadmap

Ordered by cost to run in the lab:

- [ ] **Control targets for deny checks** (I1) — a deny check only counts when its control passes.
- [ ] **Gate agent start on verification** (I2) — hold the agent *process* until the first `verified=1`, not just container start order. (A native-sidecar `startupProbe` gates container start, which is not the same thing per task.)
- [x] **Runtime matrix, runc vs gVisor** (I9): host-side NetworkPolicy vs in-pod nftables. See `experiments/`.
- [ ] **Close I2 and I3b in one configuration.** Candidates: gate the agent on the first verified probe; give the sandbox no DNS at all and resolve names at the egress proxy.
- [ ] **Runtime matrix, more cells**: gVisor with `-TESTONLY-nftables` (does in-pod enforcement work once enabled?), and Kata on a host with nested virtualization.
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
