import { z } from "zod"

export const findingSchema = z.object({
  path: z
    .string()
    .describe("File path exactly as it appears in the diff, without the a/ or b/ prefix."),
  line: z.number().int().min(1).describe("Line number that exists in the provided diff."),
  side: z
    .enum(["RIGHT", "LEFT"])
    .describe("RIGHT for added/context lines, LEFT for removed lines."),
  severity: z.enum(["critical", "high", "medium", "low"]),
  title: z.string().describe("Short, specific headline (max ~80 characters)."),
  body: z.string().describe("What is wrong and how to fix it. Concrete, 2-5 sentences, no filler."),
  suggestion: z
    .string()
    .optional()
    .describe(
      "Exact replacement text for a small, precise fix within the commented lines. Omit when the fix is not a drop-in replacement.",
    ),
  startLine: z
    .number()
    .int()
    .min(1)
    .optional()
    .describe(
      "First line of a multi-line suggestion range (inclusive). Omit for single-line suggestions.",
    ),
})

export const reviewResultSchema = z.object({
  summary: z.string().describe("2-5 sentence overview of the change and the assessment."),
  verdict: z.enum(["looks_good", "needs_changes"]),
  findings: z.array(findingSchema),
  fixedThreadIds: z
    .array(z.string())
    .optional()
    .describe(
      "GraphQL node ids of prior bot review threads whose issues are fixed by the current code. Only include threads listed in the prompt.",
    ),
})

export type Finding = z.infer<typeof findingSchema>
export type ReviewResult = z.infer<typeof reviewResultSchema>
