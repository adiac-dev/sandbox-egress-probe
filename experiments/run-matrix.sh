#!/usr/bin/env bash
# Run the I2 / I3 / I9 matrix: N fresh pods per cell, one JSON line per pod -> results/<run>.jsonl
#
# cells (runtime × where enforcement lives):
#   control-runc     no enforcement, runc     -> proves the targets are reachable (Finding 3)
#   control-gvisor   no enforcement, gVisor   -> same, under gVisor
#   host-runc        host-side NetworkPolicy, runc
#   host-gvisor      host-side NetworkPolicy, gVisor
#   nft-runc         in-pod nftables (init container), runc
#   nft-gvisor       in-pod nftables (init container), gVisor
#
# usage:  N=10 ./run-matrix.sh            all cells
#         CELLS="host-gvisor nft-gvisor" N=3 ./run-matrix.sh
set -euo pipefail
cd "$(dirname "$0")"
CLUSTER="${CLUSTER:-$(kind get clusters | head -1)}"
N="${N:-10}"
CELLS="${CELLS:-control-runc control-gvisor host-runc host-gvisor nft-runc nft-gvisor}"
IMG=exp-probe:dev
RUN="results/$(date +%Y%m%d-%H%M%S).jsonl"
mkdir -p results

echo "== build + load image into kind ($CLUSTER)"
docker build -q -t $IMG . >/dev/null
kind load docker-image $IMG --name "$CLUSTER" >/dev/null

echo "== namespaces, policy, nft rules"
KUBEDNS=$(kubectl -n kube-system get svc kube-dns -o jsonpath='{.spec.clusterIP}')
kubectl apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Namespace
metadata: {name: exp-open}
---
apiVersion: v1
kind: Namespace
metadata: {name: exp-hostpol}
---
# host-side enforcement: default-deny egress, only kube-dns allowed (same shape as the lab's 10-netpol.yaml)
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: default-deny-egress, namespace: exp-hostpol}
spec:
  podSelector: {}
  policyTypes: [Egress]
  egress:
  - to:
    - namespaceSelector: {matchLabels: {kubernetes.io/metadata.name: kube-system}}
      podSelector: {matchLabels: {k8s-app: kube-dns}}
    ports: [{protocol: UDP, port: 53}, {protocol: TCP, port: 53}]
---
# in-pod enforcement: same intent, programmed inside the pod's netns
apiVersion: v1
kind: ConfigMap
metadata: {name: nft-rules, namespace: exp-open}
data:
  rules.nft: |
    table inet sbx {
      chain out {
        type filter hook output priority 0; policy drop;
        oifname "lo" accept
        ct state established,related accept
        ip daddr $KUBEDNS udp dport 53 accept
        ip daddr $KUBEDNS tcp dport 53 accept
      }
    }
EOF

pod_yaml() {   # $1 cell  $2 name
  local cell=$1 name=$2 ns runtime enforcement rc="" init=""
  case $cell in
    control-*) ns=exp-open;    enforcement=none ;;
    host-*)    ns=exp-hostpol; enforcement=networkpolicy ;;
    nft-*)     ns=exp-open;    enforcement=nft-in-pod ;;
  esac
  case $cell in *-gvisor) runtime=gvisor; rc="runtimeClassName: gvisor" ;; *) runtime=runc ;; esac
  if [[ $enforcement == nft-in-pod ]]; then
    # Deliberately lenient (exit 0 on failure), like a sidecar that logs an error and carries on.
    # The probe reports what actually happened, so we can tell fail-open from fail-closed.
    init="initContainers:
  - name: firewall
    image: $IMG
    imagePullPolicy: Never
    command: [sh, -c, 'out=\$(nft -f /rules/rules.nft 2>&1) && echo installed > /shared/nft-status || echo \"FAILED: \$out\" > /shared/nft-status; exit 0']
    securityContext: {capabilities: {add: [NET_ADMIN]}}
    volumeMounts: [{name: rules, mountPath: /rules}, {name: shared, mountPath: /shared}]"
  fi
  cat <<EOF
apiVersion: v1
kind: Pod
metadata: {name: $name, namespace: $ns, labels: {app: exp-probe}}
spec:
  restartPolicy: Never
  $rc
  $init
  containers:
  - name: probe
    image: $IMG
    imagePullPolicy: Never
    env:
    - {name: CELL, value: $cell}
    - {name: RUNTIME, value: $runtime}
    - {name: ENFORCEMENT, value: $enforcement}
    volumeMounts: [{name: shared, mountPath: /shared}]
  volumes:
  - {name: shared, emptyDir: {}}
  - {name: rules, configMap: {name: nft-rules, optional: true}}
EOF
}

ns_of() { case $1 in host-*) echo exp-hostpol ;; *) echo exp-open ;; esac; }

for cell in $CELLS; do
  for i in $(seq 1 "$N"); do
    name="exp-$cell-$i-$RANDOM"; ns=$(ns_of "$cell")
    pod_yaml "$cell" "$name" | kubectl apply -f - >/dev/null
    if kubectl -n "$ns" wait --for=jsonpath='{.status.phase}'=Succeeded "pod/$name" --timeout=120s >/dev/null 2>&1; then
      kubectl -n "$ns" logs "$name" -c probe | tail -1 >> "$RUN"
      printf "."
    else
      phase=$(kubectl -n "$ns" get pod "$name" -o jsonpath='{.status.phase}/{.status.containerStatuses[0].state}' 2>/dev/null || true)
      echo "{\"cell\":\"$cell\",\"error\":\"not completed\",\"status\":$(printf '%s' "$phase" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))')}" >> "$RUN"
      printf "x"
    fi
    kubectl -n "$ns" delete pod "$name" --wait=false >/dev/null
  done
  echo " $cell"
done

echo "== results: $RUN"
python3 summarize.py "$RUN"
