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
})

export const reviewResultSchema = z.object({
  summary: z.string().describe("2-5 sentence overview of the change and the assessment."),
  verdict: z.enum(["looks_good", "needs_changes"]),
  findings: z.array(findingSchema),
})

export type Finding = z.infer<typeof findingSchema>
export type ReviewResult = z.infer<typeof reviewResultSchema>
