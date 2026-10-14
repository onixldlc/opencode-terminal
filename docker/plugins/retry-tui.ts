// The TUI half: native /retry commands, which cost nothing to run.
//
// opencode has two kinds of slash command and they behave very differently. A
// command/*.md file is a prompt template: typing it submits the expanded text as
// a turn and the model answers it. The built-ins -- /agents, /expand, /share --
// are not that; they are palette commands registered inside the TUI, and they
// just run. This registers the second kind, so changing the retry policy neither
// sends a message nor spends a token.
//
// Palette commands take no arguments (`run()` is called with none), and typing
// `/retry 400` would miss the command and be sent to the model as text. So the
// values here are presets, and `!retry 400 60 6h` in shell mode stays the way to
// set an arbitrary one.
//
// A plugin module default-exports either server() or tui(), never both, and one
// loaded from a path must carry an id. The server half is retry-server.ts.

import { readFileSync, writeFileSync, mkdirSync } from "node:fs"
import { dirname, join } from "node:path"

type Policy = { max?: number; base?: number; cap?: number; deadline?: string }

const CONFIG_PATH = join(
  process.env.XDG_CONFIG_HOME || join(process.env.HOME || "", ".config"),
  "opencode",
  "retry.json",
)

function read(): any {
  try {
    return JSON.parse(readFileSync(CONFIG_PATH, "utf8"))
  } catch {
    return {}
  }
}

function describe(doc: any): string {
  const d: Policy = doc.default ?? {}
  const secs = (ms: number) => (ms % 60000 === 0 ? `${ms / 60000}m` : `${Math.round(ms / 1000)}s`)
  const parts = [
    `${d.max ?? 200} attempts`,
    `up to ${secs(d.cap ?? 60000)} apart`,
    `giving up after ${d.deadline ?? "3h"}`,
  ]
  const provs = Object.keys(doc.providers ?? {})
  if (provs.length) parts.push(`overrides: ${provs.join(", ")}`)
  return parts.join(", ")
}

function write(api: any, patch: Policy, label: string) {
  try {
    const doc = read()
    doc.default = { ...(doc.default ?? {}), ...patch }
    mkdirSync(dirname(CONFIG_PATH), { recursive: true })
    writeFileSync(CONFIG_PATH, JSON.stringify(doc, null, 2) + "\n")
    api.ui.toast({
      title: `Retry: ${label}`,
      message: `${describe(doc)}. Applies to the next request.`,
      variant: "success",
    })
  } catch (e: any) {
    api.ui.toast({ title: "Retry", message: `could not write ${CONFIG_PATH}: ${e?.message ?? e}`, variant: "error" })
  }
}

const PRESETS: Record<string, { title: string; label: string; patch: Policy }> = {
  "retry.stock": {
    title: "Retry: stock (5 attempts, ~1 min)",
    label: "stock",
    patch: { max: 5, cap: 30000, deadline: "5m" },
  },
  "retry.long": {
    title: "Retry: long (200 attempts, ~3h)",
    label: "long",
    patch: { max: 200, base: 2000, cap: 60000, deadline: "3h" },
  },
  "retry.marathon": {
    title: "Retry: marathon (2000 attempts, 24h)",
    label: "marathon",
    patch: { max: 2000, base: 2000, cap: 60000, deadline: "24h" },
  },
}

const tui = async (api: any) => {
  const commands = [
    {
      name: "retry.show",
      title: "Retry policy",
      desc: "Show how long a busy provider is retried",
      category: "Session",
      namespace: "palette",
      slashName: "retry",
      run() {
        api.ui.toast({
          title: "Retry policy",
          message: `${describe(read())}. Presets: /retry-stock, /retry-long, /retry-marathon. Any value: !retry 400 60 6h`,
          variant: "info",
          duration: 8000,
        })
      },
    },
    ...Object.entries(PRESETS).map(([name, preset]) => ({
      name,
      title: preset.title,
      category: "Session",
      namespace: "palette",
      slashName: name.replace(".", "-"),
      run() {
        write(api, preset.patch, preset.label)
      },
    })),
  ]

  // keymap.registerLayer is the current API; command.register is the older name
  // for the same thing and is kept as a fallback so this survives either.
  if (api.keymap?.registerLayer) api.keymap.registerLayer({ commands })
  else if (api.command?.register) {
    api.command.register(() =>
      commands.map((c) => ({
        value: c.name,
        title: c.title,
        category: c.category,
        slash: { name: c.slashName },
        onSelect: c.run,
      })),
    )
  }
}

export default { id: "opencode-terminal-retry-tui", tui }
