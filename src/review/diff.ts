export type DiffSide = "RIGHT" | "LEFT"

export interface FileAnchors {
  path: string
  /** Line numbers in the new version (added + context lines). */
  right: Set<number>
  /** Line numbers in the old version (removed + context lines). */
  left: Set<number>
}

export interface DiffIndex {
  files: Map<string, FileAnchors>
}

const HUNK_RE = /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/

function cleanPath(raw: string): string | null {
  let value = raw.trim()

  if (value.startsWith('"') && value.endsWith('"')) {
    value = value.slice(1, -1).replaceAll('\\"', '"').replaceAll("\\\\", "\\")
  }

  if (value === "/dev/null") return null
  if (value.startsWith("a/") || value.startsWith("b/")) value = value.slice(2)
  return value
}

function ensureFile(index: DiffIndex, path: string): FileAnchors {
  const existing = index.files.get(path)
  if (existing) return existing

  const created: FileAnchors = { path, right: new Set(), left: new Set() }
  index.files.set(path, created)
  return created
}

/**
 * Parses a unified diff into the line numbers GitHub accepts as inline
 * comment anchors. A line that is not in a hunk makes GitHub reject the whole
 * review with a 422.
 */
export function indexUnifiedDiff(diff: string): DiffIndex {
  const index: DiffIndex = { files: new Map() }

  let current: FileAnchors | null = null
  let oldPath: string | null = null
  let oldLine = 0
  let newLine = 0

  for (const line of diff.split("\n")) {
    if (line.startsWith("diff --git ")) {
      current = null
      oldPath = null
      continue
    }

    // File headers must be checked before the +/- line rules.
    if (line.startsWith("--- ")) {
      oldPath = cleanPath(line.slice(4))
      continue
    }

    if (line.startsWith("+++ ")) {
      const newPath = cleanPath(line.slice(4))
      const path = newPath ?? oldPath
      current = path ? ensureFile(index, path) : null
      continue
    }

    const hunk = HUNK_RE.exec(line)
    if (hunk) {
      oldLine = Number.parseInt(hunk[1] ?? "0", 10)
      newLine = Number.parseInt(hunk[3] ?? "0", 10)
      continue
    }

    if (!current) continue

    if (line.startsWith("+")) {
      current.right.add(newLine)
      newLine += 1
      continue
    }

    if (line.startsWith("-")) {
      current.left.add(oldLine)
      oldLine += 1
      continue
    }

    if (line.startsWith(" ")) {
      current.right.add(newLine)
      current.left.add(oldLine)
      oldLine += 1
      newLine += 1
    }
  }

  return index
}

export function canAnchor(index: DiffIndex, path: string, line: number, side: DiffSide): boolean {
  const file = index.files.get(path)
  if (!file) return false
  return side === "RIGHT" ? file.right.has(line) : file.left.has(line)
}

/** Splits a unified diff into one block per file (`diff --git ...`). */
export function splitDiffByFile(diff: string): string[] {
  const blocks: string[] = []
  let current: string[] = []

  for (const line of diff.split("\n")) {
    if (line.startsWith("diff --git ") && current.length > 0) {
      blocks.push(current.join("\n"))
      current = []
    }
    current.push(line)
  }

  if (current.length > 0) blocks.push(current.join("\n"))
  return blocks.filter((block) => block.trim().length > 0)
}

/** Groups file blocks into chunks below `maxChars`, splitting large files by hunk. */
export function chunkDiffBySize(diff: string, maxChars: number): string[] {
  const chunks: string[] = []
  let current = ""

  const push = (piece: string): void => {
    if (current && current.length + piece.length + 1 > maxChars) {
      chunks.push(current)
      current = ""
    }
    current = current ? `${current}\n${piece}` : piece
  }

  for (const file of splitDiffByFile(diff)) {
    if (file.length <= maxChars) {
      push(file)
      continue
    }

    const { header, hunks } = splitFileIntoHunks(file)

    if (hunks.length === 0) {
      push(file)
      continue
    }

    for (const hunk of hunks) {
      push(`${header}\n${hunk}`)
    }
  }

  if (current) chunks.push(current)
  return chunks
}

function splitFileIntoHunks(file: string): { header: string; hunks: string[] } {
  const lines = file.split("\n")
  const firstHunk = lines.findIndex((line) => line.startsWith("@@"))

  if (firstHunk === -1) return { header: file, hunks: [] }

  const header = lines.slice(0, firstHunk).join("\n")
  const hunks: string[] = []
  let current: string[] = []

  for (const line of lines.slice(firstHunk)) {
    if (line.startsWith("@@") && current.length > 0) {
      hunks.push(current.join("\n"))
      current = []
    }
    current.push(line)
  }

  if (current.length > 0) hunks.push(current.join("\n"))
  return { header, hunks }
}

export interface ClippedDiff {
  diff: string
  truncated: boolean
  originalChars: number
}

/** Cuts a diff at a file boundary so the model never receives half a hunk. */
export function clipDiff(diff: string, maxChars: number): ClippedDiff {
  const originalChars = diff.length
  if (originalChars <= maxChars) {
    return { diff, truncated: false, originalChars }
  }

  const boundary = diff.lastIndexOf("\ndiff --git ", maxChars)
  const cutAt = boundary > 0 ? boundary : maxChars
  const clipped = diff.slice(0, cutAt)

  return {
    diff: `${clipped}\n\n[diff truncado: se muestran ${clipped.length} de ${originalChars} caracteres]\n`,
    truncated: true,
    originalChars,
  }
}
