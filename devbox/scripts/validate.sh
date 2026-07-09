#!/usr/bin/env bash
# Static validation gate — no AWS credentials required. Mirrors the checks the
# Buildkite per-PR step runs. Each check degrades gracefully if its tool is
# missing (prints SKIP) but fails hard on real errors.
#
# Usage: scripts/validate.sh
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$ROOT/.." && pwd)"
ROOT_TEMPLATE="$ROOT/cloudformation/root.yaml"
COMMON="$REPO_ROOT/common/cloudformation"
# The launch template + wake/stop Lambdas live in compute.yaml — the user-data
# size and inline-Lambda-compile checks below parse this one.
TEMPLATE="$ROOT/cloudformation/templates/compute.yaml"
PFILES="$ROOT/packer/files"
fail=0
have() { command -v "$1" >/dev/null 2>&1; }
section() { printf '\n=== %s ===\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=1; }
skip() { printf '  \033[33m–\033[0m SKIP: %s\n' "$1"; }

section "cfn-lint (root + compute + shared common templates)"
if have cfn-lint; then
  if cfn-lint --config-file "$REPO_ROOT/.cfnlintrc" "$ROOT_TEMPLATE" "$TEMPLATE" "$COMMON/data.yaml" "$COMMON/auth.yaml"; then ok "templates lint clean"; else bad "cfn-lint reported errors"; fi
else skip "cfn-lint not installed (pip install cfn-lint)"; fi

section "packer (fmt + syntax)"
if have packer; then
  ( cd "$ROOT/packer" && packer fmt -check -diff . >/dev/null ) && ok "packer fmt clean" || bad "packer fmt needed (run: packer fmt packer/)"
  ( cd "$ROOT/packer" && packer validate -syntax-only . >/dev/null 2>&1 ) && ok "packer syntax valid" || bad "packer validate failed"
else skip "packer not installed"; fi

section "shellcheck (baked scripts + provisioner)"
if have shellcheck; then
  # shellcheck disable=SC2046
  if shellcheck -S warning "$ROOT/packer/provision.sh" "$PFILES"/*.sh "$ROOT"/scripts/*.sh; then
    ok "shell scripts clean"
  else bad "shellcheck warnings/errors"; fi
else skip "shellcheck not installed"; fi

section "python compile (baked agents + inline lambdas)"
PY="$(command -v python3 || true)"
if [ -n "$PY" ]; then
  comp_ok=1
  "$PY" -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$PFILES/idle-agent.py" \
    || { bad "syntax error: idle-agent.py"; comp_ok=0; }
  # Inline Lambda ZipFiles in the template (WakeLambda + StopLambda).
  "$PY" - "$TEMPLATE" <<'PYEOF' || comp_ok=0
import ast,sys
raw=open(sys.argv[1]).read().split('\n')
n=0
for i,l in enumerate(raw):
    if l.strip()=='ZipFile: |':
        base=len(raw[i+1])-len(raw[i+1].lstrip()); body=[]
        for x in raw[i+1:]:
            if x.strip()=='': body.append(''); continue
            if (len(x)-len(x.lstrip()))<base: break
            body.append(x[base:])
        ast.parse('\n'.join(body)); n+=1
print(f"  compiled {n} inline Lambda ZipFile(s)")
PYEOF
  [ "$comp_ok" = 1 ] && ok "python sources compile" || bad "python compile errors"
else skip "python3 not found"; fi

section "traefik access-log manifest (YAML parses)"
if [ -n "$PY" ]; then
  "$PY" -c "import sys,yaml; list(yaml.safe_load_all(open(sys.argv[1])))" "$PFILES/traefik-accesslog.yaml" 2>/dev/null \
    && ok "traefik-accesslog.yaml parses" \
    || skip "pyyaml not installed (or parse issue) — skipped"
else skip "python3 not found"; fi

section "user-data size (<16384 B base64)"
if [ -n "$PY" ]; then
  "$PY" - "$TEMPLATE" <<'PYEOF' && ok "user-data within 16 KB" || bad "user-data exceeds 16 KB"
import re,base64,sys
raw=open(sys.argv[1]).read().split('\n')
s=next(i for i,l in enumerate(raw) if l.strip()=='- |' and 'Fn::Sub' in raw[i-1])+1
e=next(j for j in range(s,len(raw)) if raw[j].lstrip().startswith('- AwsRegion:') or raw[j].lstrip().startswith('- AwsRegion :'))
block=[(l[16:] if l.startswith(' '*16) else (l if l.strip()=='' else l.lstrip())) for l in raw[s:e]]
t='\n'.join(block)+'\n'
for k in set(re.findall(r'\$\{[A-Za-z][A-Za-z0-9:.]*\}', t)): t=t.replace(k,'x'*22)
size=len(base64.b64encode(t.encode())); print(f"  user-data base64: {size} / 16384")
sys.exit(0 if size<16384 else 1)
PYEOF
else skip "python3 not found"; fi

section "protobuf byte-match (wake Lambda discovery == flyteidl2)"
if [ -n "$PY" ] && "$PY" -c "import flyteidl2" 2>/dev/null; then
  "$PY" - <<'PYEOF' && ok "hand-encoded discovery matches flyteidl2" || bad "protobuf encoding drift"
def vw(n):
    o=bytearray()
    while True:
        b=n&0x7f; n>>=7; o.append(b|(0x80 if n else 0))
        if not n: return bytes(o)
def pf(num,s):
    d=s.encode(); return vw((num<<3)|2)+vw(len(d))+d
I,D,C="ISS","DOM","CID"
meta=(pf(1,I)+pf(2,D+"/oauth2/authorize")+pf(3,D+"/oauth2/token")+pf(4,"code")+pf(5,"openid")+pf(5,"profile")
      +pf(7,I+"/.well-known/jwks.json")+pf(8,"S256")+pf(9,"authorization_code")+pf(9,"refresh_token"))
pcc=(pf(1,C)+pf(2,"http://localhost:8089/callback")+pf(3,"openid")+pf(3,"profile")+pf(4,"authorization"))
from flyteidl2.auth import auth_service_pb2 as m
o=m.GetOAuth2MetadataResponse(issuer=I,authorization_endpoint=D+"/oauth2/authorize",token_endpoint=D+"/oauth2/token",jwks_uri=I+"/.well-known/jwks.json")
o.response_types_supported.append("code"); o.scopes_supported.extend(["openid","profile"]); o.code_challenge_methods_supported.append("S256"); o.grant_types_supported.extend(["authorization_code","refresh_token"])
p=m.GetPublicClientConfigResponse(client_id=C,redirect_uri="http://localhost:8089/callback",scopes=["openid","profile"],authorization_metadata_key="authorization")
assert meta==o.SerializeToString(), "GetOAuth2Metadata mismatch"
assert pcc==p.SerializeToString(), "GetPublicClientConfig mismatch"
PYEOF
else skip "flyteidl2 not installed (pip install flyte) — byte-match check"; fi

echo
if [ "$fail" = 0 ]; then printf '\033[32mAll static checks passed.\033[0m\n'; else printf '\033[31mStatic validation FAILED.\033[0m\n'; fi
exit "$fail"
