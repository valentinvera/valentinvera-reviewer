import { describe, expect, test } from "bun:test"
import {
  canAnchor,
  chunkDiffBySize,
  clipDiff,
  indexUnifiedDiff,
  splitDiffByFile,
} from "../src/review/diff"

const DIFF = `diff --git a/src/app.ts b/src/app.ts
index 1111111..2222222 100644
--- a/src/app.ts
+++ b/src/app.ts
@@ -1,4 +1,5 @@
 import { x } from "./x"
-const old = 1
+const updated = 2
+const extra = 3
 console.log(updated)
 export { updated }
@@ -20,3 +21,3 @@ function later() {
   return 1
-  return 2
+  return 3
 }
diff --git a/new-file.ts b/new-file.ts
new file mode 100644
index 0000000..3333333
--- /dev/null
+++ b/new-file.ts
@@ -0,0 +1,2 @@
+export const a = 1
+export const b = 2
`

describe("review diff anchors", () => {
  const index = indexUnifiedDiff(DIFF)

  test("indexes added and context lines on the right side", () => {
    expect(canAnchor(index, "src/app.ts", 1, "RIGHT")).toBe(true)
    expect(canAnchor(index, "src/app.ts", 2, "RIGHT")).toBe(true)
    expect(canAnchor(index, "src/app.ts", 3, "RIGHT")).toBe(true)
    expect(canAnchor(index, "src/app.ts", 4, "RIGHT")).toBe(true)
  })

  test("indexes removed lines on the left side", () => {
    expect(canAnchor(index, "src/app.ts", 2, "LEFT")).toBe(true)
    expect(canAnchor(index, "src/app.ts", 6, "LEFT")).toBe(false)
  })

  test("handles the second hunk with the right offsets", () => {
    expect(canAnchor(index, "src/app.ts", 21, "RIGHT")).toBe(true)
    expect(canAnchor(index, "src/app.ts", 22, "RIGHT")).toBe(true)
    expect(canAnchor(index, "src/app.ts", 23, "RIGHT")).toBe(true)
    expect(canAnchor(index, "src/app.ts", 22, "LEFT")).toBe(true)
  })

  test("handles new files", () => {
    expect(canAnchor(index, "new-file.ts", 1, "RIGHT")).toBe(true)
    expect(canAnchor(index, "new-file.ts", 2, "RIGHT")).toBe(true)
    expect(canAnchor(index, "new-file.ts", 3, "RIGHT")).toBe(false)
  })

  test("rejects unknown files", () => {
    expect(canAnchor(index, "does-not-exist.ts", 1, "RIGHT")).toBe(false)
  })
})

describe("clipDiff", () => {
  test("keeps small diffs untouched", () => {
    const clipped = clipDiff(DIFF, DIFF.length + 10)
    expect(clipped.truncated).toBe(false)
    expect(clipped.diff).toBe(DIFF)
  })

  test("cuts at a file boundary", () => {
    const clipped = clipDiff(DIFF, DIFF.indexOf("diff --git a/new-file.ts"))
    expect(clipped.truncated).toBe(true)
    expect(clipped.diff).toContain("src/app.ts")
    expect(clipped.diff).not.toContain("new-file.ts")
    expect(clipped.diff).toContain("diff truncado")
  })
})

describe("chunkDiffBySize", () => {
  test("splits one block per file", () => {
    const blocks = splitDiffByFile(DIFF)
    expect(blocks).toHaveLength(2)
    expect(blocks[0]).toContain("src/app.ts")
    expect(blocks[1]).toContain("new-file.ts")
  })

  test("groups files under the size limit", () => {
    const chunks = chunkDiffBySize(DIFF, 400)
    expect(chunks.length).toBeGreaterThan(1)
    for (const chunk of chunks) expect(chunk).toContain("diff --git")
  })

  test("splits large files into hunk chunks", () => {
    const chunks = chunkDiffBySize(DIFF, 10)
    expect(chunks.length).toBeGreaterThanOrEqual(3)
    for (const chunk of chunks) expect(chunk).toContain("diff --git")
  })

  test("splits large files by hunk", () => {
    const chunks = chunkDiffBySize(DIFF, 300)
    expect(chunks.length).toBeGreaterThan(1)
    for (const chunk of chunks) {
      expect(chunk).toContain("diff --git")
      expect(chunk).toContain("@@")
    }
  })
})
