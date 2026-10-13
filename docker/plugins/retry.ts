// Tells the retry proxy how hard to try, per request.
//
// opencode's own retry schedule is hardcoded in its binary (5 attempts, roughly
// a minute) and no config key or hook reaches it. The container runs every model
// request through oc-retry-proxy instead, which does the retrying; this plugin
// is how the policy gets there. It stamps one header on each outbound call, so
// editing retry.json changes the behaviour of the session already running -- no
// restart, no rebuild.
//
// Nothing here is load-bearing: a request without the header still gets the
// proxy's env defaults, so a typo in retry.json costs you the override, not the
// session.

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

const CONFIG_PATH = join(
  process.env.XDG_CONFIG_HOME || join(process.env.HOME || "", ".config"),
  "opencode",
  "retry.json",
)

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

export const RetryPolicy = async () => ({
  "chat.headers": async (input: any, output: any) => {
    const cfg = load()
    const provider = input?.provider?.id ?? input?.model?.providerID
    const policy = { ...(cfg.default ?? {}), ...((provider && cfg.providers?.[provider]) || {}) }
    const header = encode(policy)
    if (header) output.headers["x-oc-retry"] = header
  },
})
