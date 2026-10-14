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

const POLL_MS = 3_000       // how often to ask the proxy what it is doing
const REMIND_MS = 60_000    // how often to re-toast while it is still retrying
const STATUS_POLL_MS = 1_500 // how often to ask opencode what it is doing

type Toast = (message: string, variant: string, duration?: number, title?: string) => Promise<void>

// toast bodies are one line; the provider's message can be a whole JSON blob
function oneLine(text: string, max = 120): string {
  const flat = text.replace(/\s+/g, " ").trim()
  return flat.length > max ? flat.slice(0, max - 1) + "…" : flat
}

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

// opencode's own retry ceiling, compiled into the binary as a module-level
// `var` with no config key and no env var. Only needed to render "3 of 5".
const STOCK_MAX = 5

// Watches opencode's own retries, which are a different thing from the proxy's.
// The proxy holds the connection open and never hands the failure back, so while
// it is working opencode sees a slow request, not a failed one, and schedules
// nothing. These fire when the proxy is off (OC_PROXY=off), when it gives up, or
// when an error it does not retry gets through -- exactly the cases where the
// session would otherwise go quiet.
//
// Read by polling `client.session.status()`, which answers
// `{ "<sessionID>": {type:"retry", attempt, message, next} }` while a retry is
// pending. The event stream would be the obvious route and is not usable here:
// `serverUrl` advertises a port nothing listens on, and `client.event.subscribe()`
// returns a stream that never yields in-process. Both were tried.
const watchSessions = (client: any, toast: Toast, busy: () => boolean) => {
  const seen = new Map<string, number>() // sessionID -> highest attempt seen

  const finish = (id: string) => {
    const attempts = seen.get(id)
    if (attempts === undefined) return
    seen.delete(id)
    const tries = `${attempts} ${attempts === 1 ? "retry" : "retries"}`
    // retrying only stops early because the call went through; reaching the
    // ceiling is the only way opencode stops while still failing. An interrupt
    // also lands here and reads as a recovery, which is the harmless way round.
    if (attempts >= STOCK_MAX) {
      void toast(`opencode gave up after ${tries} -- its own limit is ${STOCK_MAX}.`, "error", 8_000, "Retrying")
    } else {
      void toast(`opencode recovered after ${tries}.`, "success", 5_000, "Retrying")
    }
  }

  const tick = async () => {
    let statuses: Record<string, any>
    try {
      const res: any = await client?.session?.status()
      statuses = (res?.data ?? res) as Record<string, any>
      if (!statuses || typeof statuses !== "object") return
    } catch {
      return
    }

    for (const [id, status] of Object.entries(statuses)) {
      if (status?.type !== "retry") continue
      const attempt = status.attempt ?? 0
      if (seen.get(id) === attempt) continue // same attempt, already said so
      seen.set(id, attempt)
      // the proxy is already toasting about this provider; don't say it twice
      if (busy()) continue
      const wait = typeof status.next === "number" ? status.next - Date.now() : 0
      void toast(
        `opencode is retrying: attempt ${attempt} of ${STOCK_MAX}` +
          (wait > 0 ? `, next in ${human(wait)}` : "") +
          `. ${oneLine(status.message ?? "")}`,
        "warning",
        6_000,
        "Retrying",
      )
    }

    // a session that was retrying and no longer is has settled, one way or other
    for (const id of [...seen.keys()]) {
      if (statuses[id]?.type !== "retry" && statuses[id]?.type !== "busy") finish(id)
    }
  }

  const timer = setInterval(() => void tick(), STATUS_POLL_MS)
  timer.unref?.()
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
    const toast = async (message: string, variant: string, duration?: number, title = "Provider busy") => {
      try {
        const res: any = await client?.tui?.showToast({
          body: { title, message, variant, duration },
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

    watchSessions(client, toast, () => active)
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
