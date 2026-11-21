# experiments/ — I2, I3, I9 matrix

Measures three invariants from the main README across two runtimes and two enforcement locations:

- **I2:** is there a window after start where the agent can reach the internet?
- **I3:** (a) can it query a public resolver directly? (b) does cluster DNS forward never-seen names upstream?
- **I9:** do the answers change between runc and gVisor, and between host-side and in-pod enforcement?

| cell | runtime | enforcement |
|---|---|---|
| `control-runc` / `control-gvisor` | runc / gVisor | none — proves the targets are reachable at all |
| `host-runc` / `host-gvisor` | runc / gVisor | NetworkPolicy (host side, CNI) |
| `nft-runc` / `nft-gvisor` | runc / gVisor | nftables inside the pod (init container, `NET_ADMIN`) |

The in-pod firewall is **deliberately lenient**: if `nft` fails, the init container logs it and exits 0,
like a sidecar that reports an error and carries on. The probe records both what the firewall *said*
and what the network *did* — that's how a fail-open shows up.

## Hypotheses (written before the first run)

| # | Expectation | Why |
|---|---|---|
| H1 | `host-runc`: an open window of a few seconds on fresh pods | replicates Finding 1 |
| H2 | `host-gvisor` ≈ `host-runc` | host-side rules are outside the sandbox; the runtime shouldn't matter |
| H3 | `nft-runc`: no startup window | the init container finishes before the agent starts |
| H4 | `nft-gvisor`: either nft fails (→ fail-open) or behaves like `nft-runc` | gVisor implements its own netstack; nft support is partial ([gvisor#13796](https://github.com/google/gvisor/issues/13796)) |
| H5 | I3b forwards in **every** enforced cell | all cells allow DNS to kube-dns, and kube-dns forwards |

A hypothesis that turns out wrong is a result, not a failure. Record it as-is.

## Results — 21-11-2026, N=10 per cell

kind/kindnet on Colima (arm64), gVisor `release-20261116.0`, default runsc configuration.

| # | Outcome |
|---|---|
| H1 | ✅ `host-runc`: 10/10 open at start, median 386 ms, max 556 ms. Sub-second, not "a few seconds". |
| H2 | ✅ `host-gvisor`: 10/10 open at start, median 324 ms, max 331 ms. Same pattern as runc. |
| H3 | ✅ `nft-runc`: never open (0/10), rules installed 10/10. |
| H4 | ⚠️ `nft-gvisor`: `nft` failed 10/10 (`Unable to initialize Netlink socket`). With the lenient init, egress stayed fully open for the whole run, including direct public DNS. In runsc, nftables support is only available behind `-TESTONLY-nftables`. |
| H5 | ✅ cluster DNS forwarded a never-seen external name in every enforced cell, 40/40. |

Controls: open 10/10 under both runtimes. Raw data is in `results/` (git-ignored); this table is derived from it with `summarize.py`.

## Run

```bash
./install-gvisor.sh                 # once per cluster: runsc + RuntimeClass "gvisor" + smoke test
N=2 ./run-matrix.sh                 # dry run, ~5 min
N=10 ./run-matrix.sh                # real run, ~20-30 min
python3 summarize.py results/<file>.jsonl
```

Results are raw JSON lines in `results/`, one per pod. Keep them; the table is derived.

## Known limits

- kind on a laptop (kindnet CNI, Colima VM). Other CNIs and real nodes will differ, especially for I2.
- I3b uses `nip.io` as the external zone: `x<random>.1.2.3.4.nip.io` can only resolve to `1.2.3.4` if the label reached nip.io's servers.
- Kata is not in the matrix: it needs nested virtualization, which a laptop VM usually doesn't have.
