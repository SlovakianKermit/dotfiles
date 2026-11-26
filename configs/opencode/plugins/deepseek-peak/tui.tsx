import { Plugin } from "@opencode/plugin/tui"
import { createSignal } from "solid-js"

/**
 * DeepSeek API peak/off-peak indicator.
 *
 * Peak: 01:00-04:00 and 06:00-10:00 UTC, Monday-Friday (2x price).
 * Everything else is off-peak (half price), including weekends and
 * Chinese public holidays.
 */

const PEAK_WINDOWS: ReadonlyArray<readonly [number, number]> = [
  [1, 4],
  [6, 10],
]
const DAY_MS = 86_400_000

const RATES = {
  offPeak: { input: "$0.15", output: "$0.60" },
  peak: { input: "$0.30", output: "$1.20" },
}

type Phase = {
  peak: boolean
  until: Date
}

function utcDayStart(now: Date): number {
  return Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate())
}

/** Peak intervals from two days back to nine days ahead, sorted. */
function intervals(now: Date, holidays: ReadonlySet<string>) {
  const out: Array<{ start: number; end: number }> = []
  const base = utcDayStart(now)
  for (let offset = -2; offset <= 9; offset++) {
    const dayStart = base + offset * DAY_MS
    const day = new Date(dayStart)
    const weekday = day.getUTCDay()
    if (weekday === 0 || weekday === 6) continue
    if (holidays.has(day.toISOString().slice(0, 10))) continue
    for (const [from, to] of PEAK_WINDOWS) {
      out.push({
        start: dayStart + from * 3_600_000,
        end: dayStart + to * 3_600_000,
      })
    }
  }
  return out.sort((a, b) => a.start - b.start)
}

function phaseAt(now: Date, holidays: ReadonlySet<string>): Phase {
  const t = now.getTime()
  const all = intervals(now, holidays)
  const active = all.find((i) => t >= i.start && t < i.end)
  if (active) return { peak: true, until: new Date(active.end) }
  const next = all.find((i) => i.start > t)
  return { peak: false, until: new Date(next ? next.start : t + DAY_MS) }
}

const IRISH = new Intl.DateTimeFormat("en-GB", {
  timeZone: "Europe/Dublin",
  weekday: "short",
  hour: "2-digit",
  minute: "2-digit",
  hourCycle: "h23",
})

function irishTime(date: Date): string {
  const parts = IRISH.formatToParts(date)
  const get = (type: string) => parts.find((p) => p.type === type)?.value ?? ""
  return `${get("weekday")} ${get("hour")}:${get("minute")}`
}

function remaining(ms: number): string {
  const minutes = Math.max(0, Math.round(ms / 60_000))
  const hours = Math.floor(minutes / 60)
  const rest = minutes % 60
  return hours > 0 ? `${hours}h ${String(rest).padStart(2, "0")}m` : `${rest}m`
}

export default Plugin.define({
  id: "deepseek.pricing",
  setup(context) {
    const holidays = new Set<string>(
      Array.isArray(context.options.holidays)
        ? (context.options.holidays as string[])
        : [],
    )

    const [now, setNow] = createSignal(new Date())
    const timer = setInterval(() => setNow(new Date()), 30_000)

    const theme = context.theme

    const unregister = context.ui.slot({
      append: "sidebar.content",
      render: () => {
        const current = phaseAt(now(), holidays)
        const color = current.peak
          ? theme.text.feedback.warning.base
          : theme.text.feedback.success.base
        const rate = current.peak ? RATES.peak : RATES.offPeak

        return (
          <box flexDirection="column" paddingTop={1} gap={0}>
            <text fg={theme.text.muted}>DEEPSEEK API</text>
            <box flexDirection="row" gap={1}>
              <text fg={color}>
                {current.peak ? "● PEAK" : "● OFF-PEAK"}
              </text>
              <text fg={theme.text.muted}>
                {current.peak ? "2× price" : "½ price"}
              </text>
            </box>
            <text fg={theme.text.base}>
              until {irishTime(current.until)} (
              {remaining(current.until.getTime() - now().getTime())})
            </text>
            <text fg={theme.text.muted}>
              {rate.input} in · {rate.output} out /M
            </text>
            <text fg={theme.text.muted}>peak 01–04, 06–10 UTC</text>
            <text fg={theme.text.muted}>Mon–Fri · weekends off-peak</text>
          </box>
        )
      },
    })

    context.keymap.layer(() => ({
      mode: "global",
      priority: 10,
      commands: [
        {
          id: "deepseek.pricing",
          title: "Show DeepSeek API pricing window",
          group: "DeepSeek",
          palette: true,
          slash: { name: "deepseek", aliases: ["pricing"] },
          run: async () => {
            const current = phaseAt(new Date(), holidays)
            const rate = current.peak ? RATES.peak : RATES.offPeak
            await context.ui.dialog.alert({
              title: current.peak ? "DeepSeek API · PEAK" : "DeepSeek API · OFF-PEAK",
              message: [
                `Now: ${current.peak ? "peak (2× price)" : "off-peak (half price)"}`,
                `Changes: ${irishTime(current.until)} Irish time`,
                "",
                "Peak: 01:00–04:00 and 06:00–10:00 UTC, Mon–Fri",
                "Off-peak: all other hours, weekends, CN public holidays",
                "",
                `deepseek-flash: ${rate.input} in · ${rate.output} out per 1M`,
              ].join("\n"),
            })
          },
        },
      ],
    }))

    return () => {
      clearInterval(timer)
      unregister()
    }
  },
})
