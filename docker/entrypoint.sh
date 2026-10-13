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
