// Drives the retry proxy, and reports what it is doing.
//
// This is the server half. opencode loads a plugin module by its default export,
// which must be {id, server()} or {id, tui()} -- never both, and a plugin loaded
// from a path must carry an id. The entrypoint registers this file as a file://
// entry in the config's `plugin` array; that array is the only thing loaded as a
// hooks plugin and the only thing handed a client. (A file dropped in a
// `plugins/` directory is a third loader, wanting {id, setup}, with no hooks and
// no client -- it loads into nothing.)
//
// The TUI half, which registers the /retry command, is retry-tui.ts.
//
// opencode's own retry schedule is compiled into its binary -- 5 attempts over
// about a minute, with no config key and no plugin hook to reach it. The
// container sends every model call through oc-retry-proxy instead, which does
// the retrying. This plugin is how the policy gets there: it stamps one header
// on each outbound request, so editing retry.json changes the behaviour of the
// session already running, with no restart and no rebuild.
//
// It also polls the proxy and raises a toast while a retry is in flight. Without
// that, a provider being hammered for twenty minutes looks exactly like the
// model thinking hard, and you end up typing "continue" into a session that was
// never stuck.
//
// Nothing here is load-bearing. A request that arrives without the header still
// gets the proxy's environment defaults, so a typo in retry.json costs you the
// override, not the session.

import { readFileSync, statSync } from "node:fs"
import { join } from "node:path"

type Policy = {
  max?: number      // attempts, total
  base?: number     // first backoff, ms
  cap?: number      // ceiling for one wait, ms
  deadline?: string // give up after this long, e.g. "3h", "45m"
}

type Config = {
  default?: Policy
  providers?: Record<string, Policy>
}

type Outcome = {
  host: string
  attempt: number
  elapsed_ms: number
  ok: boolean
}

type RetryState = {
  host: string
  attempt: number
  max: number
  reason: string
  next_in_ms: number
  elapsed_ms: number
}

const CONFIG_PATH = join(
  process.env.XDG_CONFIG_HOME || join(process.env.HOME || "", ".config"),
  "opencode",
  "retry.json",
)
const STATUS_URL = `http://${process.env.OC_PROXY_ADDR || "127.0.0.1:8787"}/__oc/status`

const POLL_MS = 3_000      // how often to ask the proxy what it is doing
const REMIND_MS = 60_000   // how often to re-toast while it is still retrying

let cached: Config = {}
let cachedAt = -1

// re-read only when the file actually changed, so this costs a stat per request
function load(): Config {
  try {
    const mtime = statSync(CONFIG_PATH).mtimeMs
    if (mtime !== cachedAt) {
      cached = JSON.parse(readFileSync(CONFIG_PATH, "utf8")) as Config
      cachedAt = mtime
    }
  } catch {
    // missing or malformed: fall back to the proxy's env defaults
    cached = {}
    cachedAt = -1
  }
  return cached
}

function encode(p: Policy): string {
  const parts: string[] = []
  if (typeof p.max === "number") parts.push(`max=${p.max}`)
  if (typeof p.base === "number") parts.push(`base=${p.base}`)
  if (typeof p.cap === "number") parts.push(`cap=${p.cap}`)
  if (typeof p.deadline === "string") parts.push(`deadline=${p.deadline}`)
  return parts.join(";")
}

function human(ms: number): string {
  const s = Math.round(ms / 1000)
  if (s < 60) return `${s}s`
  const m = Math.floor(s / 60)
  if (m < 60) return `${m}m ${s % 60}s`
  return `${Math.floor(m / 60)}h ${m % 60}m`
}

const server = async ({ client }: any) => {
  // one watcher per process, however many times the module is evaluated
  if (!(globalThis as any).__ocRetryWatcher) {
    ;(globalThis as any).__ocRetryWatcher = true

    let announced = 0        // when the current episode was last toasted
    let active = false       // whether an episode is in flight

    // the client handed to a plugin is the raw generated one: the payload goes
    // in `body`. Passing the fields flat answers 400 "Expected object, got
    // undefined" and resolves normally, so a wrong shape here is silent --
    // which is exactly how this went unnoticed. Anything other than 200 is
    // printed rather than swallowed.
    const toast = async (message: string, variant: string, duration?: number) => {
      try {
        const res: any = await client?.tui?.showToast({
          body: { title: "Provider busy", message, variant, duration },
        })
        if (res?.error) console.error("[retry] toast rejected:", JSON.stringify(res.error))
      } catch (e: any) {
        console.error("[retry] toast failed:", e?.message ?? e)
      }
    }

    const tick = async () => {
      let live: RetryState[] = []
      let last: Outcome | undefined
      try {
        const res = await fetch(STATUS_URL)
        const body = (await res.json()) as any
        live = body.retrying ?? []
        last = body.last ?? undefined
      } catch {
        return // proxy not running, or disabled: nothing to report
      }

      if (live.length > 0) {
        const worst = live.reduce((a, b) => (b.elapsed_ms > a.elapsed_ms ? b : a))
        active = true
        const now = Date.now()
        if (now - announced > REMIND_MS) {
          announced = now
          void toast(
            `${worst.host} returned ${worst.reason}. Retry ${worst.attempt}/${worst.max}` +
              `, next in ${human(worst.next_in_ms)} (waiting ${human(worst.elapsed_ms)}).` +
              ` Still working -- no need to send anything.`,
            "warning",
            8_000,
          )
        }
        return
      }

      // the episode ended. Report how, so a session that gave up is never
      // mistaken for one that came back on its own.
      if (active) {
        active = false
        announced = 0
        if (!last) return
        const tries = `${last.attempt} ${last.attempt === 1 ? "retry" : "retries"}`
        if (last.ok) {
          void toast(`${last.host} recovered after ${tries} over ${human(last.elapsed_ms)}.`, "success", 5_000)
        } else {
          void toast(
            `${last.host} never recovered -- gave up after ${tries} over ${human(last.elapsed_ms)}.`,
            "error",
            8_000,
          )
        }
      }
    }

    const timer = setInterval(() => void tick(), POLL_MS)
    timer.unref?.()
  }

  return {
    "chat.headers": async (input: any, output: any) => {
      const cfg = load()
      const provider = input?.provider?.id ?? input?.model?.providerID
      const policy = { ...(cfg.default ?? {}), ...((provider && cfg.providers?.[provider]) || {}) }
      const header = encode(policy)
      if (header) output.headers["x-oc-retry"] = header
    },
  }
}

export default { id: "opencode-terminal-retry", server }
