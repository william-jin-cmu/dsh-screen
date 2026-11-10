/** A native helper child that speaks JSON lines. Shared source; esbuild bundles a copy into each plugin that imports it. */
import { spawn, type ChildProcessWithoutNullStreams } from 'node:child_process'
import { accessSync, chmodSync, constants, existsSync } from 'node:fs'
import { dirname, resolve } from 'node:path'
import { fileURLToPath } from 'node:url'

/** bin/<name> beside the plugin's dist/ (the built layout) or its src/ (running from source). */
export function helperPath(importMetaUrl: string, name: string): string | undefined {
  const path = resolve(dirname(fileURLToPath(importMetaUrl)), '..', 'bin', name)
  if (!existsSync(path)) return undefined
  // Package managers do not always keep the executable bit of files outside the manifest's `bin`.
  try {
    accessSync(path, constants.X_OK)
  } catch {
    try {
      chmodSync(path, 0o755)
    } catch {
      return undefined
    }
  }
  return path
}

export interface HelperOptions {
  readonly path: string
  readonly args: readonly string[]
  /** One parsed stdout line. */
  readonly onMessage: (message: Record<string, unknown>) => void
  /** The child went away. `expected` is true after `stop()`. */
  readonly onExit?: (info: { code: number | null; expected: boolean; stderr: string }) => void
}

export class HelperProcess {
  private child: ChildProcessWithoutNullStreams | undefined
  private stopped = false
  private stderr = ''

  constructor(private readonly options: HelperOptions) {}

  get running(): boolean {
    return this.child !== undefined
  }

  start(): void {
    if (this.child !== undefined || this.stopped) return
    const child = spawn(this.options.path, [...this.options.args], { stdio: ['pipe', 'pipe', 'pipe'] })
    this.child = child
    let buffer = ''
    child.stdout.setEncoding('utf8')
    child.stdout.on('data', (chunk: string) => {
      buffer += chunk
      for (;;) {
        const newline = buffer.indexOf('\n')
        if (newline === -1) break
        const line = buffer.slice(0, newline)
        buffer = buffer.slice(newline + 1)
        if (line.trim() === '') continue
        try {
          const parsed: unknown = JSON.parse(line)
          if (parsed !== null && typeof parsed === 'object') this.options.onMessage(parsed as Record<string, unknown>)
        } catch {
          // A helper never prints non-JSON on stdout; ignore a torn line rather than crash the host.
        }
      }
    })
    child.stderr.setEncoding('utf8')
    child.stderr.on('data', (chunk: string) => {
      this.stderr = (this.stderr + chunk).slice(-4000)
    })
    child.stdin.on('error', () => {})
    child.on('error', () => {})
    child.on('close', (code) => {
      if (this.child === child) this.child = undefined
      this.options.onExit?.({ code, expected: this.stopped, stderr: this.stderr })
    })
  }

  send(message: Record<string, unknown>): boolean {
    if (this.child === undefined || !this.child.stdin.writable) return false
    this.child.stdin.write(`${JSON.stringify(message)}\n`)
    return true
  }

  /** Helpers exit on stdin EOF; SIGTERM follows if one lingers. */
  stop(): void {
    this.stopped = true
    const child = this.child
    if (child === undefined) return
    child.stdin.end()
    setTimeout(() => {
      if (child.exitCode === null) child.kill('SIGTERM')
    }, 1500).unref()
  }
}

/** Request/response on top of a HelperProcess whose replies echo the request `id`. */
export class HelperRpc {
  private nextId = 1
  private readonly pending = new Map<number, { resolve: (value: Record<string, unknown>) => void; reject: (error: Error) => void; timer: NodeJS.Timeout }>()

  constructor(private readonly helper: HelperProcess) {}

  /** Feed every helper message here; returns true when it was a reply. */
  accept(message: Record<string, unknown>): boolean {
    if (typeof message.id !== 'number') return false
    const entry = this.pending.get(message.id)
    if (entry === undefined) return false
    this.pending.delete(message.id)
    clearTimeout(entry.timer)
    entry.resolve(message)
    return true
  }

  call(op: string, params: Record<string, unknown> = {}, timeoutMs = 15_000): Promise<Record<string, unknown>> {
    return new Promise((resolvePromise, reject) => {
      const id = this.nextId++
      const timer = setTimeout(() => {
        this.pending.delete(id)
        reject(new Error(`helper did not answer "${op}" within ${timeoutMs}ms`))
      }, timeoutMs)
      this.pending.set(id, { resolve: resolvePromise, reject, timer })
      if (!this.helper.send({ id, op, ...params })) {
        this.pending.delete(id)
        clearTimeout(timer)
        reject(new Error('helper is not running'))
      }
    })
  }

  failAll(reason: string): void {
    for (const [id, entry] of this.pending) {
      clearTimeout(entry.timer)
      entry.reject(new Error(reason))
      this.pending.delete(id)
    }
  }
}
