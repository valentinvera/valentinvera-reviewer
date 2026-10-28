import { config, type LogLevel } from "./config"

const LEVELS: Record<LogLevel, number> = {
  debug: 10,
  info: 20,
  warn: 30,
  error: 40,
}

export type LogContext = Record<string, unknown>

function write(level: LogLevel, msg: string, context?: LogContext): void {
  if (LEVELS[level] < LEVELS[config.logLevel]) return

  const line = JSON.stringify({
    ts: new Date().toISOString(),
    level,
    msg,
    ...context,
  })

  // Keep stdout clean for CLI output (`review:dry-run --json`).
  console.error(line)
}

export const log = {
  debug: (msg: string, context?: LogContext) => write("debug", msg, context),
  info: (msg: string, context?: LogContext) => write("info", msg, context),
  warn: (msg: string, context?: LogContext) => write("warn", msg, context),
  error: (msg: string, context?: LogContext) => write("error", msg, context),
}

export function errorMessage(error: unknown): string {
  if (error instanceof Error) return error.message
  return typeof error === "string" ? error : JSON.stringify(error)
}
