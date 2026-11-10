/** Pure formatting and range parsing for the screen tools. */

export interface Range {
  fromMs: number
  toMs: number
  label: string
}

/** `last` (30m | 2h | 1d) beats `day` (today | yesterday | YYYY-MM-DD); the default is today. */
export function parseRange(input: { day?: string; last?: string }, now = new Date()): Range | { error: string } {
  if (input.last !== undefined && input.last !== '') {
    const match = /^(\d+)\s*([mhd])$/.exec(input.last.trim())
    if (!match) return { error: `"last" must look like 30m, 2h or 1d (got "${input.last}")` }
    const unit = { m: 60_000, h: 3_600_000, d: 86_400_000 }[match[2] as 'm' | 'h' | 'd']
    return { fromMs: now.getTime() - Number(match[1]) * unit, toMs: now.getTime(), label: `the last ${input.last.trim()}` }
  }
  const day = (input.day ?? 'today').trim().toLowerCase()
  let start: Date
  if (day === 'today' || day === '') {
    start = new Date(now.getFullYear(), now.getMonth(), now.getDate())
  } else if (day === 'yesterday') {
    start = new Date(now.getFullYear(), now.getMonth(), now.getDate() - 1)
  } else {
    const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(day)
    if (!match) return { error: `"day" must be today, yesterday or YYYY-MM-DD (got "${input.day}")` }
    start = new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]))
  }
  const end = new Date(start.getFullYear(), start.getMonth(), start.getDate() + 1)
  return { fromMs: start.getTime(), toMs: Math.min(end.getTime(), now.getTime()), label: day === '' ? 'today' : day }
}

export function formatDuration(ms: number): string {
  const seconds = Math.round(ms / 1000)
  if (seconds < 60) return `${seconds}s`
  const minutes = Math.round(seconds / 60)
  if (minutes < 60) return `${minutes}m`
  return `${Math.floor(minutes / 60)}h ${String(minutes % 60).padStart(2, '0')}m`
}

export function formatClock(ms: number): string {
  const date = new Date(ms)
  return `${String(date.getHours()).padStart(2, '0')}:${String(date.getMinutes()).padStart(2, '0')}`
}

export function formatDateTime(ms: number): string {
  const date = new Date(ms)
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')} ${formatClock(ms)}`
}

export interface NowResult {
  app: string
  bundle: string
  title: string
  url: string
  selected: string
  text: string
  truncated: boolean
  skipped: string[]
  shot?: string
  shotError?: string
}

export function formatNow(result: NowResult): string {
  const lines = [`App: ${result.app}${result.bundle ? ` (${result.bundle})` : ''}`]
  if (result.title) lines.push(`Window: ${result.title}`)
  if (result.url) lines.push(`URL: ${result.url}`)
  if (result.skipped.length > 0) lines.push(`(In front of it: ${result.skipped.join(', ')} — skipped because it is DSH itself or an excluded app.)`)
  if (result.shot) lines.push(`Screenshot of the window: ${result.shot}`)
  if (result.shotError === 'screen_recording_denied') lines.push('No screenshot: the app DSH runs in has no Screen Recording permission (System Settings → Privacy & Security → Screen & System Audio Recording).')
  else if (result.shotError) lines.push(`No screenshot: ${result.shotError}.`)
  if (result.selected) lines.push('', 'Selected text:', result.selected)
  lines.push('', result.text ? `Visible text${result.truncated ? ' (cut short)' : ''}:` : 'This window exposes no readable text.')
  if (result.text) lines.push(result.text)
  return lines.join('\n')
}

export interface TimelineResult {
  apps: { app: string; durationMs: number }[]
  spans: { app: string; title: string; url: string; start_ms: number; end_ms: number; durationMs: number; entry?: number; excerpt?: string }[]
}

export function formatTimeline(result: TimelineResult, label: string, options: { byApp: boolean }): string {
  if (result.spans.length === 0) return `Nothing recorded for ${label}.`
  const total = result.apps.reduce((sum, app) => sum + app.durationMs, 0)
  const lines = [`Screen time for ${label}: ${formatDuration(total)} recorded`, '', 'By app:']
  for (const app of result.apps.slice(0, 15)) lines.push(`- ${app.app}: ${formatDuration(app.durationMs)}`)
  if (options.byApp) return lines.join('\n')
  lines.push('', 'Windows, in order:')
  // Cap the listing; the rollup above still covers everything.
  const spans = result.spans.length > 150 ? result.spans.slice(-150) : result.spans
  if (spans.length < result.spans.length) lines.push(`(showing the latest ${spans.length} of ${result.spans.length})`)
  for (const span of spans) {
    const where = span.url ? ` <${span.url}>` : ''
    lines.push(`${formatClock(span.start_ms)} ${formatDuration(span.durationMs).padStart(6)}  ${span.app} — ${span.title || '(untitled)'}${where}`)
    if (span.excerpt) lines.push(`        [entry ${span.entry}] ${span.excerpt}`)
  }
  return lines.join('\n')
}

export interface SearchResult {
  hits: { entry: number; tsMs: number; app: string; title: string; url: string; excerpt: string }[]
}

export function formatSearch(result: SearchResult, query: string, label: string): string {
  if (result.hits.length === 0) return `No screen text matching "${query}" in ${label}.`
  const lines = [`${result.hits.length} match${result.hits.length === 1 ? '' : 'es'} for "${query}" in ${label} (newest first):`]
  for (const hit of result.hits) {
    lines.push('', `[entry ${hit.entry}] ${formatDateTime(hit.tsMs)}  ${hit.app} — ${hit.title || '(untitled)'}${hit.url ? ` <${hit.url}>` : ''}`, `  ${hit.excerpt}`)
  }
  return lines.join('\n')
}
