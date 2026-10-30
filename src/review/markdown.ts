import { config } from "../config"
import type { Finding, ReviewResult } from "./schema"

const SEVERITY_LABEL: Record<Finding["severity"], string> = {
  critical: "🔴 critical",
  high: "🟠 high",
  medium: "🟡 medium",
  low: "🔵 low",
}

export function buildInlineComment(finding: Finding): string {
  return `**${SEVERITY_LABEL[finding.severity]} · ${finding.title}**\n\n${finding.body}`
}

export function buildReviewBody(input: {
  result: ReviewResult
  headSha: string
  model: string
  unanchored: Finding[]
  truncated: boolean
}): string {
  const sections: string[] = [
    "## 🤖 Review automático",
    input.result.summary || "Sin observaciones.",
  ]

  if (input.unanchored.length > 0) {
    sections.push("### Observaciones generales")
    sections.push(
      input.unanchored
        .map(
          (finding) =>
            `- **${SEVERITY_LABEL[finding.severity]} · ${finding.title}** — ${finding.body}`,
        )
        .join("\n"),
    )
  }

  if (input.result.findings.length === 0) {
    sections.push("_No encontré problemas relevantes en este diff._")
  }

  if (input.truncated) {
    sections.push("> ⚠️ El diff superaba el límite configurado y se revisó parcialmente.")
  }

  sections.push(
    `<sub>Revisado \`${input.headSha.slice(0, 10)}\` · ${input.model} · ${input.result.findings.length} hallazgo(s)</sub>`,
  )

  return sections.join("\n\n")
}

export function buildRateLimitNotice(kind: "auto" | "manual"): string {
  if (config.reviewLanguage === "en") {
    return kind === "auto"
      ? "⏳ Automatic review limit reached for this pull request. Reviews will resume once the 24-hour window allows."
      : "⏳ Manual review limit reached for this pull request. Please try again later."
  }

  return kind === "auto"
    ? "⏳ Se alcanzó el límite de reviews automáticos de este PR. Se reanudarán cuando lo permita la ventana de 24 horas."
    : "⏳ Se alcanzó el límite de reviews manuales de este PR. Intentá de nuevo más tarde."
}

export function buildSummaryComment(input: {
  result: ReviewResult
  headSha: string
  model: string
  reviewUrl: string
  trigger: string
}): string {
  const status = input.result.findings.length === 0 ? "✅ Sin hallazgos" : "📝 Revisado"
  const lines = [
    "### 🤖 valentinvera-reviewer",
    "",
    "| Estado | Commit | Hallazgos | Disparador |",
    "| --- | --- | --- | --- |",
    `| ${status} | \`${input.headSha.slice(0, 10)}\` | ${input.result.findings.length} | ${input.trigger} |`,
    "",
    `[Ver review completa](${input.reviewUrl})`,
    "",
    `<sub>${input.model} · este comentario se actualiza en cada push</sub>`,
  ]

  return lines.join("\n")
}
