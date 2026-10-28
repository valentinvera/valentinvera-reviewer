import { describe, expect, test } from "bun:test"
import { MockLanguageModelV4 } from "ai/test"
import { config } from "../src/config"
import { chunkDiffBySize } from "../src/review/diff"
import { generateReview } from "../src/review/engine"
import type { ReviewPullRequest } from "../src/review/prompt"

const pr: ReviewPullRequest = {
  number: 51,
  title: "feat: change things",
  body: "Some context",
  author: "valentinvera",
  baseRef: "main",
  headRef: "feat/change",
  baseSha: "b".repeat(40),
  headSha: "a".repeat(40),
  changedFiles: 1,
  additions: 1,
  deletions: 1,
}

const diff = `diff --git a/src/a.ts b/src/a.ts
index 1111111..2222222 100644
--- a/src/a.ts
+++ b/src/a.ts
@@ -1,2 +1,2 @@
 const a = 1
-const b = 2
+const b = 3
`

const modelResult = {
  summary: "  Hay un cambio riesgoso.  ",
  verdict: "needs_changes" as const,
  findings: [
    {
      path: "a/src/a.ts",
      line: 2,
      side: "RIGHT" as const,
      severity: "high" as const,
      title: "  Bug real  ",
      body: "  Esto rompe el flujo.  ",
    },
    {
      path: "src/a.ts",
      line: 2,
      side: "RIGHT" as const,
      severity: "high" as const,
      title: "Bug real",
      body: "Esto rompe el flujo.",
    },
    {
      path: "src/a.ts",
      line: 1,
      side: "RIGHT" as const,
      severity: "low" as const,
      title: "Menor",
      body: "Detalle menor.",
    },
  ],
}

function mockModel() {
  return new MockLanguageModelV4({
    doGenerate: {
      content: [{ type: "text", text: JSON.stringify(modelResult) }],
      finishReason: { unified: "stop", raw: "stop" },
      usage: {
        inputTokens: { total: 10, noCache: 10, cacheRead: 0, cacheWrite: 0 },
        outputTokens: { total: 20, text: 20, reasoning: 0 },
      },
      warnings: [],
    },
  })
}

function bigDiff(): string {
  const lines = Array.from({ length: 600 }, (_, index) => `+const value${index} = ${index}`).join(
    "\n",
  )

  const file = (path: string) =>
    `diff --git a/${path} b/${path}\n--- a/${path}\n+++ b/${path}\n@@ -1,0 +1,600 @@\n${lines}\n`

  return file("src/a.ts") + file("src/b.ts")
}

function chunkResult(index: number) {
  return {
    content: [
      {
        type: "text" as const,
        text: JSON.stringify({
          summary: `Parte ${index + 1}`,
          verdict: "needs_changes",
          findings: [
            {
              path: `src/f${index}.ts`,
              line: 1,
              side: "RIGHT",
              severity: "low",
              title: `Finding ${index}`,
              body: `Body ${index}`,
            },
          ],
        }),
      },
    ],
    finishReason: { unified: "stop" as const, raw: "stop" },
    usage: {
      inputTokens: { total: 10, noCache: 10, cacheRead: 0, cacheWrite: 0 },
      outputTokens: { total: 20, text: 20, reasoning: 0 },
    },
    warnings: [],
  }
}

describe("generateReview", () => {
  test("parses, normalizes and deduplicates the structured result", async () => {
    const model = mockModel()
    const generated = await generateReview({ repo: "valentinvera/plata", pr, diff, model })

    expect(generated.result.summary).toBe("Hay un cambio riesgoso.")
    expect(generated.result.findings).toHaveLength(2)
    expect(generated.result.findings[0]).toMatchObject({
      path: "src/a.ts",
      line: 2,
      title: "Bug real",
      body: "Esto rompe el flujo.",
    })
    expect(generated.clipped.truncated).toBe(false)
    expect(generated.usage).toMatchObject({
      inputTokens: 10,
      outputTokens: 20,
      totalTokens: 30,
    })
    expect(model.doGenerateCalls[0]?.responseFormat?.type).toBe("json")
  })

  test("chunks large diffs and merges partial results", async () => {
    const diff = bigDiff()
    const chunks = chunkDiffBySize(diff, config.reviewChunkChars)
    expect(chunks.length).toBeGreaterThan(1)

    const model = new MockLanguageModelV4({
      doGenerate: chunks.map((_, index) => chunkResult(index)),
    })

    const generated = await generateReview({ repo: "valentinvera/plata", pr, diff, model })

    expect(model.doGenerateCalls).toHaveLength(chunks.length)
    expect(generated.result.findings).toHaveLength(chunks.length)
    expect(generated.result.summary).toContain("Revisión dividida en")
    expect(generated.usage?.totalTokens).toBe(30 * chunks.length)
  })
})
