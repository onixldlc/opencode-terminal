#!/usr/bin/env bash
# Seeds the mounted config dir on first run, turns the env knobs into an inline
# config override, then hands over to opencode.
set -euo pipefail

CONFIG_HOME="${XDG_CONFIG_HOME:-$HOME/.config}"
DATA_HOME="${XDG_DATA_HOME:-$HOME/.local/share}"
STATE_HOME="${XDG_STATE_HOME:-$HOME/.local/state}"
OC_CONFIG_DIR="$CONFIG_HOME/opencode"
OC_DATA_DIR="$DATA_HOME/opencode"
SEED_DIR="${OPENCODE_SEED_DIR:-/opt/opencode}"

mkdir -p "$OC_CONFIG_DIR" "$OC_DATA_DIR"

# opencode creates its own dir under the XDG state home. The image ships that
# path dev-owned; this only matters if a parent came from somewhere else (an
# older image, a custom mount) and is unwritable — say so instead of dying on
# an EACCES stack trace.
if ! mkdir -p "$STATE_HOME" 2>/dev/null; then
  echo "[opencode-terminal] cannot create $STATE_HOME (owned by $(stat -c '%U:%G' "$(dirname "$STATE_HOME")" 2>/dev/null || echo unknown))." >&2
  echo "[opencode-terminal] pull a newer image, or set XDG_STATE_HOME to a writable path." >&2
fi

# ─── first-run seeding ───
# Only ever creates missing files, so a config the user edited is never touched.
if [[ "${OPENCODE_SKIP_SEED:-0}" != "1" ]]; then
  if [[ ! -e "$OC_CONFIG_DIR/opencode.jsonc" && ! -e "$OC_CONFIG_DIR/opencode.json" ]]; then
    sed "s|__MODEL__|${OPENCODE_DEFAULT_MODEL:-zai/glm-5.3}|" \
      "$SEED_DIR/opencode.default.jsonc" > "$OC_CONFIG_DIR/opencode.jsonc"
    echo "[opencode-terminal] seeded $OC_CONFIG_DIR/opencode.jsonc" >&2
  fi

  if [[ ! -e "$OC_CONFIG_DIR/AGENTS.md" ]]; then
    cp "$SEED_DIR/AGENTS.default.md" "$OC_CONFIG_DIR/AGENTS.md"
    echo "[opencode-terminal] seeded $OC_CONFIG_DIR/AGENTS.md" >&2
  fi

  # cli.json is the TUI's own config, separate from opencode.jsonc. Shipping it
  # with session.thinking=show keeps reasoning expanded; the in-TUI toggle
  # rewrites this same file.
  if [[ ! -e "$OC_CONFIG_DIR/cli.json" ]]; then
    cp "$SEED_DIR/cli.default.json" "$OC_CONFIG_DIR/cli.json"
    echo "[opencode-terminal] seeded $OC_CONFIG_DIR/cli.json" >&2
  fi

  # retry.json drives the proxy through the seeded plugin. Both are copied, never
  # overwritten -- edits survive an image upgrade.
  if [[ ! -e "$OC_CONFIG_DIR/retry.json" ]]; then
    cp "$SEED_DIR/retry.default.json" "$OC_CONFIG_DIR/retry.json"
    echo "[opencode-terminal] seeded $OC_CONFIG_DIR/retry.json" >&2
  fi
  # plugins/ (plural) is auto-loaded by opencode. The `plugin` array in
  # opencode.jsonc is for npm package names only -- a path there is treated as a
  # package and fails to install.
  if [[ ! -e "$OC_CONFIG_DIR/plugins/retry.ts" ]]; then
    mkdir -p "$OC_CONFIG_DIR/plugins"
    cp "$SEED_DIR/plugins/retry.ts" "$OC_CONFIG_DIR/plugins/retry.ts"
    echo "[opencode-terminal] seeded $OC_CONFIG_DIR/plugins/retry.ts" >&2
  fi
fi

# ─── retry proxy ───
# opencode's own retry schedule is 5 attempts over about a minute, hardcoded in
# its binary with no config key and no plugin hook. Every outbound request goes
# through oc-retry-proxy instead, which absorbs 429s and 5xx for as long as the
# policy says. It intercepts TLS rather than rewriting baseURLs, so it covers
# every provider -- including ones added later -- with no per-provider config.
#
# The CA is generated per container into the mounted config dir on first run and
# never leaves it. A CA baked into a published image would be a private key
# everybody holding the image has.
if [[ "${OC_PROXY:-on}" != "off" ]]; then
  PROXY_DIR="$CONFIG_HOME/opencode-terminal"
  PROXY_ADDR="${OC_PROXY_ADDR:-127.0.0.1:8787}"
  mkdir -p "$PROXY_DIR"
  OC_PROXY_CA_DIR="$PROXY_DIR" OC_PROXY_ADDR="$PROXY_ADDR" \
    oc-retry-proxy >>"$PROXY_DIR/proxy.log" 2>&1 &

  # wait for the listener rather than sleeping blind; a dead proxy with the env
  # vars already exported would take every request down with it
  for _ in $(seq 1 50); do
    if (exec 3<>"/dev/tcp/${PROXY_ADDR%:*}/${PROXY_ADDR##*:}") 2>/dev/null; then
      exec 3<&- 3>&-
      break
    fi
    sleep 0.1
  done

  if (exec 3<>"/dev/tcp/${PROXY_ADDR%:*}/${PROXY_ADDR##*:}") 2>/dev/null; then
    exec 3<&- 3>&-
    # trust the proxy's CA: bun reads NODE_EXTRA_CA_CERTS, everything else in the
    # image reads one of the bundle variables
    cat /etc/ssl/certs/ca-certificates.crt "$PROXY_DIR/ca.pem" > "$PROXY_DIR/bundle.pem"

    # bun honours NODE_EXTRA_CA_CERTS on a direct connection but ignores it for
    # tunnelled requests, which is exactly the path every provider call takes.
    # The system store is read either way, so the CA goes in there. This is the
    # container's own store, thrown away with the container -- the host's is
    # untouched, and the key was generated locally in the mounted config dir.
    if [[ -f "$PROXY_DIR/ca.pem" ]] && sudo -n true 2>/dev/null; then
      sudo install -m 644 "$PROXY_DIR/ca.pem" /usr/local/share/ca-certificates/oc-retry-proxy.crt
      if sudo update-ca-certificates >/dev/null 2>&1; then
        [[ -n "${OPENCODE_TERMINAL_DEBUG:-}" ]] && echo "[opencode-terminal] proxy CA added to the container trust store" >&2
      else
        echo "[opencode-terminal] could not refresh the trust store; set OC_PROXY_INSECURE=1 if provider calls fail with a certificate error." >&2
      fi
    fi

    # last resort, opt-in only: opencode stops verifying certificates and trusts
    # the local proxy blindly. The proxy still verifies the real provider, so the
    # unverified hop is 127.0.0.1 -- but anything else in the container inherits
    # this too, so it stays off unless asked for.
    if [[ "${OC_PROXY_INSECURE:-0}" == "1" ]]; then
      export NODE_TLS_REJECT_UNAUTHORIZED=0
      echo "[opencode-terminal] OC_PROXY_INSECURE=1: TLS verification disabled inside the container." >&2
    fi

    export NODE_EXTRA_CA_CERTS="$PROXY_DIR/ca.pem"
    export SSL_CERT_FILE="$PROXY_DIR/bundle.pem"
    export CURL_CA_BUNDLE="$PROXY_DIR/bundle.pem"
    export REQUESTS_CA_BUNDLE="$PROXY_DIR/bundle.pem"
    export HTTPS_PROXY="http://$PROXY_ADDR" HTTP_PROXY="http://$PROXY_ADDR"
    export https_proxy="$HTTPS_PROXY" http_proxy="$HTTP_PROXY"
    export NO_PROXY="localhost,127.0.0.1,::1"
    export no_proxy="$NO_PROXY"
    [[ -n "${OPENCODE_TERMINAL_DEBUG:-}" ]] && echo "[opencode-terminal] retry proxy on $PROXY_ADDR" >&2
  else
    echo "[opencode-terminal] retry proxy did not start, continuing without it." >&2
    echo "[opencode-terminal] opencode will fall back to its own 5 attempts. See $PROXY_DIR/proxy.log" >&2
  fi
fi


# ─── env knobs → inline config ───
# OPENCODE_CONFIG_CONTENT is opencode's highest-precedence source and merges
# into the files rather than replacing them: scalars win, arrays append. That
# keeps --model / --system-prompt style overrides out of the persistent config.
RUN_DIR=""
if [[ -n "${OPENCODE_SYSTEM_PROMPT:-}" ]]; then
  RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/opencode-run.XXXXXX")"
  printf '%s\n' "$OPENCODE_SYSTEM_PROMPT" > "$RUN_DIR/system-prompt.md"
fi

if [[ -n "${OPENCODE_SYSTEM_PROMPT_FILE:-}" && ! -r "${OPENCODE_SYSTEM_PROMPT_FILE}" ]]; then
  echo "[opencode-terminal] OPENCODE_SYSTEM_PROMPT_FILE=${OPENCODE_SYSTEM_PROMPT_FILE} is not readable" >&2
  exit 1
fi

OVERRIDE="$(
  RUN_DIR="$RUN_DIR" python3 - <<'PY'
import json, os

override = {}
instructions = []

model = os.environ.get("OPENCODE_MODEL", "").strip()
if model:
    override["model"] = model

agent = os.environ.get("OPENCODE_SMALL_MODEL", "").strip()
if agent:
    override["small_model"] = agent

run_dir = os.environ.get("RUN_DIR", "")
if run_dir:
    instructions.append(os.path.join(run_dir, "system-prompt.md"))

prompt_file = os.environ.get("OPENCODE_SYSTEM_PROMPT_FILE", "").strip()
if prompt_file:
    instructions.append(prompt_file)

if instructions:
    override["instructions"] = instructions

# A caller-supplied inline config stays authoritative: its keys land last.
existing = os.environ.get("OPENCODE_CONFIG_CONTENT", "").strip()
if existing:
    try:
        parsed = json.loads(existing)
    except json.JSONDecodeError as e:
        raise SystemExit(f"OPENCODE_CONFIG_CONTENT is not valid JSON: {e}")
    if not isinstance(parsed, dict):
        raise SystemExit("OPENCODE_CONFIG_CONTENT must be a JSON object")
    merged_instructions = override.get("instructions", []) + parsed.pop("instructions", [])
    override.update(parsed)
    if merged_instructions:
        override["instructions"] = merged_instructions

print(json.dumps(override) if override else "")
PY
)"

if [[ -n "$OVERRIDE" ]]; then
  export OPENCODE_CONFIG_CONTENT="$OVERRIDE"
  [[ -n "${OPENCODE_TERMINAL_DEBUG:-}" ]] && echo "[opencode-terminal] inline config: $OVERRIDE" >&2
fi

# No key, no providers: every GLM provider on models.dev authenticates through
# ZHIPU_API_KEY, and `opencode auth login` is the alternative. A completed login
# is stored in the `credential` table of opencode.db (auth.json is the legacy
# location), so the presence of either file means credentials may already exist
# and the hint would be noise.
if [[ -z "${ZHIPU_API_KEY:-}" && ! -e "$OC_DATA_DIR/auth.json" && ! -e "$OC_DATA_DIR/opencode.db" ]]; then
  echo "[opencode-terminal] no credentials yet: export ZHIPU_API_KEY, or run 'opencode auth login' once ('/connect' inside the TUI)." >&2
  echo "[opencode-terminal] a login is saved in $OC_DATA_DIR/opencode.db and persists in the mounted config dir." >&2
fi

exec opencode "$@"
