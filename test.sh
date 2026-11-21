#!/usr/bin/env bash
# Expected: 4 PASS — clone allowed; push, other host and proxy bypass all blocked
set -uo pipefail
X="kubectl -n sandbox exec client -c agent --"
check() { if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (expected $2, got $3)"; fi; }

$X rm -rf /tmp/repo
$X git clone -q --depth 1 https://github.com/kubernetes-sigs/agent-sandbox /tmp/repo >/dev/null 2>&1
check "git clone github.com            -> allowed" ok "$([ $? -eq 0 ] && echo ok || echo blocked)"

out=$($X sh -c 'cd /tmp/repo && git push -q origin HEAD:refs/heads/egress-lab-test 2>&1' 2>/dev/null)
check "git push github.com             -> blocked by proxy (L7)" blocked "$(echo "$out" | grep -q 403 && echo blocked || echo other)"

code=$($X curl -s -o /dev/null -w '%{http_connect}' https://example.com 2>/dev/null)
check "curl example.com                -> blocked by proxy (CONNECT)" blocked "$([ "$code" = 403 ] && echo blocked || echo "$code")"

$X curl -s --noproxy '*' --max-time 5 -o /dev/null https://1.1.1.1 2>/dev/null
check "curl 1.1.1.1 bypassing proxy    -> blocked by NetworkPolicy" blocked "$([ $? -ne 0 ] && echo blocked || echo reachable)"

echo; echo "proxy log:"; kubectl -n egress logs deploy/egress-proxy -c mitmproxy --tail=30 | grep -E 'ALLOW|DENY' | tail -8
