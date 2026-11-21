#!/usr/bin/env bash
# Install gVisor (runsc) into every node of an existing kind cluster and register RuntimeClass "gvisor".
# Idempotent: safe to re-run.
set -euo pipefail
CLUSTER="${CLUSTER:-$(kind get clusters | head -1)}"
echo "cluster: $CLUSTER"

# gVisor now ships as one tarball (runsc + containerd-shim-runsc-v1 + gvisor-bin/), not separate binaries.
# Download + verify + extract on the Mac (bsdtar handles .bz2), then copy into each kind node.
for node in $(kind get nodes --name "$CLUSTER"); do
  echo "== $node"
  if docker exec "$node" sh -c 'command -v runsc >/dev/null'; then
    echo "runsc already installed"
  else
    ARCH=$(docker exec "$node" uname -m)          # aarch64 on Apple Silicon / Colima
    URL=https://storage.googleapis.com/gvisor/releases/release/latest/$ARCH
    TMP=$(mktemp -d)
    ( cd "$TMP"
      curl -fsSLO "$URL/gvisor.tar.bz2"
      curl -fsSLO "$URL/gvisor.tar.bz2.sha512"
      shasum -a 512 -c gvisor.tar.bz2.sha512
      mkdir out && tar -xjf gvisor.tar.bz2 -C out )
    echo "extracted: $(ls "$TMP/out" | tr '\n' ' ')"
    for f in "$TMP"/out/*; do docker cp "$f" "$node:/usr/local/bin/"; done   # keep gvisor-bin/ next to runsc
    docker exec "$node" chmod +x /usr/local/bin/runsc /usr/local/bin/containerd-shim-runsc-v1
    rm -rf "$TMP"
  fi
  docker exec "$node" runsc --version | head -1

  docker exec "$node" bash -euo pipefail -c '
    CFG=/etc/containerd/config.toml
    if ! grep -q "runtimes.runsc" $CFG; then
      # containerd 2.x (config version 3) renamed the CRI plugin
      if grep -qE "^version *= *3" $CFG; then KEY=io.containerd.cri.v1.runtime; else KEY=io.containerd.grpc.v1.cri; fi
      printf "\n[plugins.\"%s\".containerd.runtimes.runsc]\n  runtime_type = \"io.containerd.runsc.v1\"\n" $KEY >> $CFG
      systemctl restart containerd
      echo "registered runsc under $KEY"
    fi
  '
done

kubectl apply -f - <<'EOF'
apiVersion: node.k8s.io/v1
kind: RuntimeClass
metadata:
  name: gvisor
handler: runsc
EOF

# smoke test: gVisor prints its own boot messages in dmesg
kubectl run gvisor-smoke --rm -i --restart=Never --image=alpine:3.20 \
  --overrides='{"spec":{"runtimeClassName":"gvisor"}}' -- dmesg | head -3
echo "OK: gVisor works if you see 'Starting gVisor...' above"
