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

echo "== seeds =="
for f in /opt/opencode/opencode.default.jsonc /opt/opencode/AGENTS.default.md; do
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
OPENCODE_DEFAULT_MODEL="zai/glm-5.3" \
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
