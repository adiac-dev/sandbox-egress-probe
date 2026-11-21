#!/usr/bin/env bash
# Silent-failure demo: a "temporary" debug NetworkPolicy opens egress; the agent notices nothing; the probe does.
set -uo pipefail
M() { kubectl -n sandbox exec client -c probe -- curl -s localhost:9100/metrics | grep -E '^egress_(bypass_blocked|allow_canary|enforcement_verified|dns_exfil)'; }
wait_run() { echo "  ...waiting for the next probe run"; sleep 20; }

echo "== 1. baseline"; M

echo; echo "== 2. someone applies a 'temporary' debug policy"
kubectl apply -f 99-debug-allow-all.yaml
wait_run

echo; echo "== 3. the agent still works — nothing looks wrong"
kubectl -n sandbox exec client -c agent -- sh -c 'rm -rf /tmp/r && git clone -q --depth 1 https://github.com/kubernetes-sigs/agent-sandbox /tmp/r && echo "  git clone: ok"'

echo; echo "== 4. but the probe sees the gap"; M

echo; echo "== 5. cleanup"
kubectl delete -f 99-debug-allow-all.yaml
wait_run; M
