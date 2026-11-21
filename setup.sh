#!/usr/bin/env bash
# Builds the egress lab: kind cluster, lab CA, L7 egress proxy, default-deny sandbox namespace.
set -euo pipefail
cd "$(dirname "$0")"

kind get clusters | grep -qx egress-lab || kind create cluster --config kind.yaml

# 1. Lab CA (generated inside a container so macOS's LibreSSL doesn't matter)
if [ ! -f ca/mitmproxy-ca.pem ]; then
  mkdir -p ca
  docker run --rm -v "$PWD/ca":/w -w /w alpine:3.20 sh -c '
    apk add -q openssl &&
    openssl req -x509 -new -nodes -newkey rsa:2048 -days 30 \
      -keyout ca.key -out ca.crt -subj "/CN=egress-lab-ca" \
      -addext "basicConstraints=critical,CA:TRUE" \
      -addext "keyUsage=critical,keyCertSign,cRLSign" &&
    cat ca.key ca.crt > mitmproxy-ca.pem'
fi

# 2. Client image, loaded into kind (the sandbox has no internet to pull from)
docker build -q -t lab-client:v1 .
kind load docker-image lab-client:v1 --name egress-lab

# 3. Manifests + secrets
kubectl apply -f 00-namespaces.yaml
kubectl -n egress create secret generic mitm-ca --from-file=ca/mitmproxy-ca.pem --dry-run=client -o yaml | kubectl apply -f -
kubectl -n egress create configmap egress-policy --from-file=policy.py --dry-run=client -o yaml | kubectl apply -f -
kubectl -n sandbox create configmap egress-ca --from-file=ca/ca.crt --dry-run=client -o yaml | kubectl apply -f -
kubectl -n sandbox create configmap egress-probe --from-file=probe.py --dry-run=client -o yaml | kubectl apply -f -
kubectl -n sandbox delete pod client --ignore-not-found --wait=true   # Pod spec is immutable; recreate on every run
kubectl apply -f 10-netpol.yaml -f 20-proxy.yaml -f 30-client.yaml

kubectl -n egress rollout restart deploy/egress-proxy   # pick up policy.py changes
kubectl -n egress rollout status deploy/egress-proxy --timeout=180s
kubectl -n sandbox wait pod/client --for=condition=Ready --timeout=120s
echo "lab ready — run ./test.sh"
