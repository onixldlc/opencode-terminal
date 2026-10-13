/**
 * retry-longer — stretch opencode's retry gaps so a busy provider gets a real
 * chance to free up instead of giving up after ~84 seconds.
 *
 * Why this shape: the retry schedule itself is hardcoded in opencode
 * (packages/core/src/session/runner/retry.ts) as
 *
 *   Schedule.max([Schedule.min([exponential("2 seconds"), spaced("10 seconds")]),
 *                 Schedule.recurs(10)])
 *
 * i.e. 10 attempts, 2s/4s/8s then 10s each, ~84s total. The attempt COUNT is
 * out of reach from a plugin: when the schedule is exhausted the runner returns
 * { retry: false } before the hook is ever called (retry.ts:72). What IS
 * reachable is the delay — SessionRetry.decision is deliberately mutable, and
 * the runner re-reads it after the hook and honours whatever delay it finds
 * (retry.ts:78-88). The 15-minute RETRY_AFTER_MAX cap applies only to
 * provider-supplied retry-after values, not to ours.
 *
 * So: same 10 attempts, much longer gaps. At the default below that's 10 × 60s
 * ≈ 10 minutes of unattended retrying instead of 84 seconds. Ctrl-C still
 * cancels at any point.
 *
 * Tune without editing this file:
 *   OPENCODE_RETRY_DELAY_MS     flat delay per attempt   (default 60000)
 *   OPENCODE_RETRY_MAX_MS       ceiling after ramping    (default 120000)
 *   OPENCODE_RETRY_PROVIDERS    comma-separated provider ids to limit this to;
 *                               unset = every provider
 */

const BASE = Number(process.env.OPENCODE_RETRY_DELAY_MS ?? 60_000)
const CEILING = Number(process.env.OPENCODE_RETRY_MAX_MS ?? 120_000)
const SCOPE = (process.env.OPENCODE_RETRY_PROVIDERS ?? "")
  .split(",")
  .map((entry) => entry.trim())
  .filter(Boolean)

const sane = (value: number, fallback: number) =>
  Number.isFinite(value) && value >= 0 ? value : fallback

// Ramp a little rather than sitting flat: a provider that frees up fast should
// not cost a full minute, and one that is genuinely saturated gets longer gaps
// as attempts accumulate. attempt is 2-based by the time the hook sees it.
const delayFor = (attempt: number) => {
  const base = sane(BASE, 60_000)
  const ceiling = sane(CEILING, 120_000)
  return Math.min(base * Math.max(1, attempt - 1), Math.max(base, ceiling))
}

export default {
  id: "retry-longer",
  setup: async (ctx: any) => {
    const register = (options?: { providerID: string }) =>
      ctx.session.hook(
        "retry",
        (event: any) => {
          // Never resurrect a decision the runner already declined: that is
          // either schedule exhaustion or a non-retryable error, and forcing
          // retry here would loop on a permanent failure.
          if (!event?.decision?.retry) return
          event.decision = { retry: true, delay: delayFor(event.attempt ?? 1) }
        },
        options,
      )

    if (SCOPE.length === 0) {
      await register()
      return
    }
    await Promise.all(SCOPE.map((providerID) => register({ providerID })))
  },
}
