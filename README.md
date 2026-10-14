# opencode-terminal

A dockerized [opencode](https://opencode.ai) for ease of use whilst still isolated from the entire machine — the opencode counterpart to [llm-terminal](https://github.com/onixldlc/llm-terminal), wired for GLM models and custom system prompts.

Image: `ghcr.io/onixldlc/opencode-terminal:latest`

## usage

```bash
docker run -it --rm \
  -e ZHIPU_API_KEY \
  -v "$PWD/config":/home/dev \
  -v "$PWD":/home/dev/work \
  -w /home/dev/work \
  ghcr.io/onixldlc/opencode-terminal:latest
```

`config/` becomes the container `$HOME`, so credentials, sessions, plugins and your global rules survive restarts. Anything after the image name goes to `opencode`:

```bash
docker run ... ghcr.io/onixldlc/opencode-terminal:latest --version
docker run ... ghcr.io/onixldlc/opencode-terminal:latest -c            # continue last session
docker run ... ghcr.io/onixldlc/opencode-terminal:latest session list
```

For the ergonomic path — runtime autodetection, UID mapping, SELinux, per-directory session resume — use the CLI wrapper instead of a raw `docker run`.

## GLM models

Every GLM provider on [models.dev](https://models.dev) reads the **`ZHIPU_API_KEY`** env var, so exporting it on the host is all the auth you need:

| Provider id | Endpoint | Use when |
|---|---|---|
| `zai` | `api.z.ai/api/paas/v4` | Z.AI pay-as-you-go API key |
| `zai-coding-plan` | `api.z.ai/api/coding/paas/v4` | you subscribe to the GLM Coding Plan |
| `zhipuai` | `open.bigmodel.cn/api/paas/v4` | mainland Zhipu AI account |
| `zhipuai-coding-plan` | `open.bigmodel.cn/api/coding/paas/v4` | mainland coding plan |

Models are addressed `provider/model`, e.g. `zai/glm-5.3`, `zai/glm-4.7`, `zai-coding-plan/glm-5.3-highspeed`, `zai/glm-5.3-flash`. List what your key unlocks:

```bash
docker run --rm -e ZHIPU_API_KEY ghcr.io/onixldlc/opencode-terminal:latest models zai
```

The alternative is logging in once: `/connect` inside the TUI, or `opencode auth login --provider zai`. The credential goes into the `credential` table of `~/.local/share/opencode/opencode.db`, which lives in the mounted config dir — so later runs need no `-e` at all. (`auth.json` is the older location some docs still mention; opencode 1.19 writes the database.) `opencode auth list` shows what is stored, `opencode auth logout` clears it.

Pick the model per run, no config edit:

```bash
docker run ... -e OPENCODE_MODEL=zai-coding-plan/glm-5.3 ...
```

## system prompts

Three layers, all usable at once:

1. **Global rules** — `config/.config/opencode/AGENTS.md`, seeded on first run. Applies to every session in the container.
2. **Project rules** — `AGENTS.md` in the project root (opencode also falls back to `CLAUDE.md`).
3. **Per-run prompt** — `OPENCODE_SYSTEM_PROMPT` or `OPENCODE_SYSTEM_PROMPT_FILE`, appended for that container only.

```bash
docker run ... -e OPENCODE_SYSTEM_PROMPT="Answer in bullet points. Never run git push." ...
docker run ... -v "$PWD/prompts":/prompts:ro -e OPENCODE_SYSTEM_PROMPT_FILE=/prompts/reviewer.md ...
```

Per-agent system prompts go in `config/.config/opencode/opencode.jsonc`, which is seeded with a commented example:

```jsonc
{
  "agent": {
    "build": { "mode": "primary", "prompt": "{file:/home/dev/.config/opencode/AGENTS.md}" },
    "plan":  { "mode": "primary", "model": "zai/glm-5.3-flash" }
  }
}
```

## environment

| Variable | Effect |
|---|---|
| `ZHIPU_API_KEY` | Authenticates all four GLM providers |
| `OPENCODE_MODEL` | Overrides the model for this run (`provider/model`) |
| `OPENCODE_SMALL_MODEL` | Model for cheap side tasks like session titles |
| `OPENCODE_SYSTEM_PROMPT` | Literal text appended to the system prompt |
| `OPENCODE_SYSTEM_PROMPT_FILE` | Readable path appended to the system prompt |
| `OPENCODE_DEFAULT_MODEL` | Model written into the config **only** when it is seeded (default `zai/glm-5.3`) |
| `OPENCODE_SKIP_SEED=1` | Do not create `opencode.jsonc` / `AGENTS.md` / `retry.json` |
| `OPENCODE_CONFIG_CONTENT` | Your own inline JSON config; its keys win over the ones above |
| `OPENCODE_TERMINAL_DEBUG=1` | Print the assembled inline config to stderr |
| `OC_RETRY_MAX` | Proxy retry attempts before giving up (default `200`) |
| `OC_RETRY_CAP` | Ceiling for one retry delay in ms (default `60000`) |
| `OC_RETRY_BASE` | First retry delay in ms, doubling each attempt (default `2000`) |
| `OC_RETRY_DEADLINE` | Stop retrying after this long (default `3h`) |
| `OC_PROXY=off` | Don't start the retry proxy at all |
| `OC_PROXY_INSECURE=1` | Disable TLS verification inside the container (last resort) |

The overrides are applied through opencode's own `OPENCODE_CONFIG_CONTENT` layer, which **merges** into your config files — scalars replace, arrays append — so nothing in the mounted config dir is rewritten behind your back.

## what's inside

`node:22-bookworm-slim` plus the opencode CLI, the `oc-retry-proxy` binary and the same toolchain as llm-terminal: python3, go, a headless JRE, rust, ripgrep, fzf, git, passwordless sudo. Runs as `dev` (UID/GID 1000 by default).

| Path | Holds |
|---|---|
| `~/.config/opencode/opencode.jsonc` | Config: model, agents, instructions |
| `~/.config/opencode/AGENTS.md` | Global system prompt |
| `~/.config/opencode/tui.json` | TUI settings: theme, keybinds, its own `plugin` array |
| `~/.config/opencode/plugins/` | Local plugins (the `{id, setup}` kind, not hooks) |
| `~/.config/opencode/retry.json` | Retry policy, read per request |
| `~/.config/opencode-terminal/ca.pem` | The proxy's CA, generated on first run |
| `~/.local/share/opencode/opencode.db` | Credentials, sessions, messages, projects (SQLite) |
| `~/.local/share/opencode/auth.json` | Legacy credential file, if an older version wrote one |

## retries

opencode gives up on a busy provider after **5** attempts — 2s, 4s, 8s, 16s, 32s
capped to 30s, about a minute total. On a provider under load that is one "Model
busy, retry later" away from dropping your turn. The schedule is compiled into
its binary: no config key reaches it, and the plugin API has no retry hook.

So the container retries one layer down instead. `oc-retry-proxy` is a small Go
binary that every outbound request passes through; a 429 or 5xx is retried there
for as long as the policy allows, and opencode only ever sees the attempt that
worked. It intercepts TLS rather than rewriting `baseURL`s, so **every provider is
covered, including ones you add later**, with no per-provider configuration.

Default policy: 200 attempts, 2s backoff doubling to a 60s ceiling, 3h deadline.

| attempts | delay each | running total |
|---|---|---|
| 1–5 | 2s, 4s, 8s, 16s, 32s | ~60s |
| 6–200 | 60s | **~3h 15m** |

A provider's own `retry-after` header is honoured when it sends one. Requests
that would be slow to answer are held open as an event stream with SSE keepalive
comments, so a long wait doesn't trip opencode's 5-minute header timeout.

### seeing it happen

A retry that lasts twenty minutes would otherwise look exactly like the model
thinking hard, which is how you end up typing "continue" into a session that was
never stuck. The plugin polls the proxy and raises a toast:

```
Provider busy
api.deepinfra.com returned 503. Retry 7/200, next in 60s (waiting 5m 12s).
Still working -- no need to send anything.
```

repeated once a minute while it lasts, and closed out either way:

```
api.deepinfra.com recovered after 7 retries over 6m 2s.          (success)
api.deepinfra.com never recovered -- gave up after 200 retries over 3h.  (error)
```

`curl http://127.0.0.1:8787/__oc/status` from inside the container gives the
same thing as JSON, and the proxy logs every attempt to
`~/.config/opencode-terminal/proxy.log`.

opencode's *own* retries are reported too, which is a different thing. While the
proxy is working it holds the connection open and never hands the failure back,
so opencode sees a slow request rather than a failed one and schedules nothing.
These show up when the proxy is off, when it gives up, or when an error it does
not retry gets through:

```
Retrying
opencode is retrying: attempt 3 of 5, next in 8s. Too Many Requests
opencode gave up after 5 retries -- its own limit is 5.
```

That ceiling of 5 is compiled into the opencode binary — a module-level `var`
with no config key and no environment variable, which is the whole reason the
proxy exists. The status is read by polling `client.session.status()`, which
answers `{"<sessionID>": {type:"retry", attempt, message, next}}`. The event
stream would be the obvious route and does not work from a plugin: `serverUrl`
advertises a port nothing listens on, and `client.event.subscribe()` returns a
stream that never yields in-process.

### changing the policy

Slash commands, registered by the TUI half of the plugin:

```
/retry             show the current policy
/retry-stock       5 attempts, ~1 min    (what opencode does on its own)
/retry-long        200 attempts, ~3h     (the default)
/retry-marathon    2000 attempts, 24h
```

These are palette commands like `/agents` or `/expand`, so they just run -- no
message is sent and no tokens are spent. They take no arguments, though: a
palette command's `run()` is called with none, and `/retry 400` would miss the
command and be sent to the model as text. For an arbitrary value, press **`!`**
on an empty prompt for shell mode:

```
!retry 400                 400 attempts
!retry 400 60 6h           400 attempts, 60s ceiling, 6h deadline
!retry deepinfra 500       just that provider
!retry off                 back to roughly stock opencode
```

Shell mode runs the command and prints its output without prompting the model
either. (A `command/*.md` file would not: those are prompt templates, and the
expanded text is submitted as a turn.) Either way it takes effect on the next
request, with no restart.

Or edit `~/.config/opencode/retry.json` directly — it is read per request, so
edits apply to the session already running:

```json
{
  "default":   { "max": 200, "base": 2000, "cap": 60000, "deadline": "3h" },
  "providers": { "deepinfra": { "max": 400, "deadline": "6h" },
                 "zai":       { "max": 5,   "cap": 30000 } }
}
```

The server half of the plugin turns that into an `x-oc-retry` header on each
call, which the proxy reads and strips before the request goes upstream.
Requests that arrive without it get the `OC_RETRY_*` environment defaults.

### the certificate

The proxy terminates TLS, so it needs a CA. One is generated **per container on
first run** into the mounted config dir (`~/.config/opencode-terminal/ca.pem`,
key `0600`) and added to the container's own trust store at startup. No CA is
baked into the published image — that would be a private key shipped to everyone
who pulls it. Your host's trust store is never touched.

bun honours `NODE_EXTRA_CA_CERTS` for direct connections but ignores it for
tunnelled ones, which is why the CA goes into the system store rather than an
env var. If a provider call ever fails with a certificate error, `OC_PROXY=off`
disables the proxy entirely (back to opencode's 5 attempts), and
`OC_PROXY_INSECURE=1` is the blunt fallback — it stops opencode verifying
certificates at all, trusting the local proxy blindly. The proxy still verifies
the real provider in that mode, so the unverified hop is 127.0.0.1, but anything
else in the container inherits it too.

## expanded thinking

Toggle it in the TUI: `ctrl+p` -> "thinking" (the `session.toggle.thinking`
command), which persists for the session.

Earlier versions of this image seeded `cli.json` with `session.thinking: "show"`
on the belief that it was the TUI's config file. It is not -- opencode 1.19 reads
`tui.json`, and the string `cli.json` does not appear anywhere in its binary, so
that file never had any effect. The entrypoint removes it if it is still the
inert one that shipped.

On plugins: opencode 1.19 has three loaders that are easy to confuse.

| where it is registered | what it gets | export |
|---|---|---|
| `plugin` array in the opencode config | server hooks (`chat.headers`, `event`, ...) and a client | `default { id, server() }` |
| `plugin` array in **`tui.json`** | the TUI api: palette commands, toasts, theme, kv | `default { id, tui() }` |
| a `{plugin,plugins}/*.ts` file in a config dir | agents, commands, skills | `default { id, setup() }` |

One module exports `server()` or `tui()`, never both, and a plugin loaded from a
path must carry an `id`. The retry plugin is two files for exactly that reason:
`retry-server.ts` stamps the header, `retry-tui.ts` registers the commands. The
entrypoint registers the first through `OPENCODE_CONFIG_CONTENT` and the second
through `OPENCODE_TUI_CONFIG`, so neither needs a file you own to be edited.

## build locally

```bash
docker build -f docker/Dockerfile -t opencode-terminal:dev \
  --build-arg UID=$(id -u) --build-arg GID=$(id -g) .

# toolchain, seeding, GLM provider resolution, env overrides
docker run --rm --entrypoint /usr/local/bin/opencode-verify.sh opencode-terminal:dev
```

Pin a different opencode release with `--build-arg OPENCODE_VERSION=1.19.0`.

## versioning

The **major** tracks [llm-terminal](https://github.com/onixldlc/llm-terminal) — currently `1.x` (`1.1.1-r2` on GHCR), so this starts at `1.1.0`. Minor and patch are this repo's own: they are fixes against opencode, and those don't translate one-to-one to the claude image.

`VERSION` holds the tag verbatim, `v` included — currently `v1.1.0`. That value becomes the image tag (`v1.1.0`, alongside `latest`) and the git tag. llm-terminal's `-rN` rebuild counter still exists, but it is no longer computed by scanning the registry: to rebuild the same code, write the revision into the file yourself.

```bash
echo v1.1.0-r2 > VERSION   # same code, second build
```

## releasing

No `git tag` needed. Edit **`VERSION`** on `main` — from the web editor is fine — and the push builds, smoke tests, pushes `vX.Y.Z` + `latest` to GHCR, then creates the tag and release.

```bash
echo v1.1.1 > VERSION
git commit -am "release v1.1.1" && git push
```

Build without publishing: Actions → Build and Push → Run workflow → untick **publish**.
