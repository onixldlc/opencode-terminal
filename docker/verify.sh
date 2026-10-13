#!/usr/bin/env bash
# Image self-check. Run in CI after the build, or by hand:
#   docker run --rm --entrypoint /usr/local/bin/opencode-verify.sh <image>
set -uo pipefail

fail=0
ok()   { printf '  ok    %s\n' "$*"; }
bad()  { printf '  FAIL  %s\n' "$*"; fail=1; }

echo "== toolchain =="
for bin in opencode node npm python3 go java rustc cargo rg git fzf; do
  if command -v "$bin" >/dev/null 2>&1; then
    ok "$bin -> $(command -v "$bin")"
  else
    bad "$bin missing from PATH"
  fi
done

echo "== opencode =="
ver="$(opencode --version 2>&1 | tail -1)"
if [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+ ]]; then
  ok "version $ver"
else
  bad "unexpected --version output: $ver"
fi

if [[ -n "${EXPECTED_OPENCODE_VERSION:-}" && "$ver" != "${EXPECTED_OPENCODE_VERSION}" ]]; then
  bad "version $ver != expected ${EXPECTED_OPENCODE_VERSION}"
fi

echo "== retry proxy =="
[[ -x /usr/local/bin/oc-retry-proxy ]] && ok "oc-retry-proxy present" || bad "oc-retry-proxy missing"
for v in OC_RETRY_MAX OC_RETRY_CAP OC_RETRY_BASE OC_RETRY_DEADLINE; do
  [[ -n "${!v:-}" ]] && ok "$v=${!v}" || bad "$v not set in the image"
done

proxy_dir="$(mktemp -d)"
OC_PROXY_CA_DIR="$proxy_dir" OC_PROXY_ADDR=127.0.0.1:8799 oc-retry-proxy >"$proxy_dir/log" 2>&1 &
proxy_pid=$!
for _ in $(seq 1 50); do
  (exec 3<>/dev/tcp/127.0.0.1/8799) 2>/dev/null && { exec 3<&- 3>&-; break; }
  sleep 0.1
done

if (exec 3<>/dev/tcp/127.0.0.1/8799) 2>/dev/null; then
  exec 3<&- 3>&-
  ok "proxy listening on 127.0.0.1:8799"
else
  bad "proxy did not start: $(tail -1 "$proxy_dir/log" 2>/dev/null)"
fi
[[ -s "$proxy_dir/ca.pem" ]] && ok "generated its own CA" || bad "no CA generated"
if HOME="$proxy_dir" retry 42 >/dev/null 2>&1 && grep -q '"max": 42' "$proxy_dir/.config/opencode/retry.json" 2>/dev/null; then
  ok "retry/oc-retry writes the policy file (run it from TUI shell mode)"
else
  bad "oc-retry did not update the policy file"
fi
status="$(curl -s --max-time 5 http://127.0.0.1:8799/__oc/status || true)"
if grep -q '"retrying"' <<<"$status"; then
  ok "status endpoint answers (the TUI plugin polls this)"
else
  bad "status endpoint did not answer: $status"
fi
[[ "$(stat -c '%a' "$proxy_dir/ca.key" 2>/dev/null)" == "600" ]] && ok "CA key is 0600" || bad "CA key permissions are not 0600"

# the trust-store install is what makes bun accept the intercepted connection:
# it ignores NODE_EXTRA_CA_CERTS on tunnelled requests but reads the system store
if sudo -n install -m 644 "$proxy_dir/ca.pem" /usr/local/share/ca-certificates/oc-verify.crt 2>/dev/null \
   && sudo -n update-ca-certificates >/dev/null 2>&1; then
  ok "proxy CA installs into the container trust store"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 25 -x http://127.0.0.1:8799 https://api.z.ai/api/paas/v4/models 2>/dev/null || true)"
  if [[ "$code" =~ ^[0-9]{3}$ && "$code" != "000" ]]; then
    ok "intercepted https through the proxy with no explicit --cacert (got $code)"
  else
    echo "   skip: no network, could not check interception end to end" >&2
  fi
  sudo -n rm -f /usr/local/share/ca-certificates/oc-verify.crt 2>/dev/null
  sudo -n update-ca-certificates >/dev/null 2>&1
else
  bad "could not install the proxy CA into the trust store (sudo missing?)"
fi
kill "$proxy_pid" 2>/dev/null
rm -rf "$proxy_dir"

echo "== seeds =="
for f in /opt/opencode/opencode.default.jsonc /opt/opencode/AGENTS.default.md \
         /opt/opencode/cli.default.json /opt/opencode/retry.default.json \
         /opt/opencode/plugins/retry.ts; do
  [[ -r "$f" ]] && ok "$f" || bad "$f missing"
done

echo "== xdg tree =="
# These must exist in the image and be writable by dev. If they don't, podman
# creates them root-owned while making the bind-mount targets, and opencode
# dies with EACCES on mkdir '/home/dev/.local/state'.
for d in /home/dev/.config /home/dev/.local /home/dev/.local/share /home/dev/.local/state /home/dev/.cache; do
  if [[ -d "$d" && -w "$d" ]]; then
    ok "$d writable ($(stat -c '%U:%G %a' "$d"))"
  else
    bad "$d missing or not writable by $(id -un)"
  fi
done

# Everything below runs against a throwaway HOME so the check never writes into
# a mounted config dir.
probe="$(mktemp -d)"
export HOME="$probe"
mkdir -p "$probe/work"
cd "$probe/work" || exit 1

echo "== entrypoint seeding =="
OC_PROXY=off OPENCODE_DEFAULT_MODEL="zai/glm-5.3" \
  /usr/local/bin/opencode-entrypoint.sh --version >/dev/null 2>&1
if [[ -r "$probe/.config/opencode/opencode.jsonc" ]]; then
  ok "seeded opencode.jsonc"
  if grep -q '"model": "zai/glm-5.3"' "$probe/.config/opencode/opencode.jsonc"; then
    ok "__MODEL__ rendered"
  else
    bad "__MODEL__ placeholder not rendered"
  fi
else
  bad "entrypoint did not seed opencode.jsonc"
fi
[[ -r "$probe/.config/opencode/AGENTS.md" ]] && ok "seeded AGENTS.md" || bad "AGENTS.md not seeded"
[[ -r "$probe/.config/opencode/cli.json" ]] && ok "seeded cli.json" || bad "cli.json not seeded"
[[ -r "$probe/.config/opencode/retry.json" ]] && ok "seeded retry.json" || bad "retry.json not seeded"
[[ -r "$probe/.config/opencode/plugins/retry.ts" ]] && ok "seeded plugins/retry.ts" || bad "plugins/retry.ts not seeded"

# Everything below runs against a throwaway HOME so the check never writes into
# a mounted config dir.
probe="$(mktemp -d)"
export HOME="$probe"
mkdir -p "$probe/work"
cd "$probe/work" || exit 1

echo "== entrypoint seeding =="
OC_PROXY=off OPENCODE_DEFAULT_MODEL="zai/glm-5.3" \
  /usr/local/bin/opencode-entrypoint.sh --version >/dev/null 2>&1
if [[ -r "$probe/.config/opencode/opencode.jsonc" ]]; then
  ok "seeded opencode.jsonc"
  if grep -q '"model": "zai/glm-5.3"' "$probe/.config/opencode/opencode.jsonc"; then
    ok "__MODEL__ rendered"
  else
    bad "__MODEL__ placeholder not rendered"
  fi
else
  bad "entrypoint did not seed opencode.jsonc"
fi
[[ -r "$probe/.config/opencode/AGENTS.md" ]] && ok "seeded AGENTS.md" || bad "AGENTS.md not seeded"
[[ -r "$probe/.config/opencode/cli.json" ]] && ok "seeded cli.json" || bad "cli.json not seeded"
[[ -r "$probe/.config/opencode/retry.json" ]] && ok "seeded retry.json" || bad "retry.json not seeded"
[[ -r "$probe/.config/opencode/plugins/retry.ts" ]] && ok "seeded plugins/retry.ts" || bad "plugins/retry.ts not seeded"

echo "== glm providers =="
# Every GLM provider on models.dev authenticates via ZHIPU_API_KEY, so a dummy
# value is enough to prove the provider list resolves. No request is made.
models="$(ZHIPU_API_KEY=dummy opencode models 2>&1)"
for want in zai/ zai-coding-plan/ zhipuai/; do
  if grep -q "^${want}" <<<"$models"; then
    ok "provider ${want%/} present"
  else
    bad "provider ${want%/} missing from 'opencode models'"
  fi
done
if grep -qE '^zai/glm-' <<<"$models"; then
  ok "GLM model ids listed ($(grep -cE '^zai/glm-' <<<"$models") under zai/)"
else
  bad "no zai/glm-* model ids"
fi

echo "== system prompt + model override =="
resolved="$(OPENCODE_MODEL="zai/glm-4.7" OPENCODE_SYSTEM_PROMPT="be terse" \
  /usr/local/bin/opencode-entrypoint.sh debug config 2>/dev/null)"
if grep -q '"zai/glm-4.7"' <<<"$resolved"; then
  ok "OPENCODE_MODEL reached the resolved config"
else
  bad "OPENCODE_MODEL did not reach the resolved config: $resolved"
fi
if grep -q 'system-prompt.md' <<<"$resolved"; then
  ok "OPENCODE_SYSTEM_PROMPT added to instructions"
else
  bad "OPENCODE_SYSTEM_PROMPT missing from instructions: $resolved"
fi

rm -rf "$probe"

if [[ $fail -eq 0 ]]; then
  echo "verify: PASS"
else
  echo "verify: FAIL"
fi
exit $fail
