import { Octokit } from "octokit"
import { config } from "../src/config"
import { generateReview } from "../src/review/engine"
import type { ReviewPullRequest } from "../src/review/prompt"

function usage(): never {
  console.error(`Usage: bun run review:dry-run <owner/repo> <pr-number> [--json]

Requires GITHUB_TOKEN (read-only) and OPENCODE_API_KEY.
This command never posts to GitHub; it only prints the generated review.`)
  process.exit(2)
}

const argv = Bun.argv.slice(2)
const positional = argv.filter((arg) => !arg.startsWith("--"))
const flags = new Set(argv.filter((arg) => arg.startsWith("--")))

const repo = positional[0]
const prNumber = Number.parseInt(positional[1] ?? "", 10)

if (!repo || !Number.isFinite(prNumber)) usage()
if (!config.githubToken) {
  console.error("GITHUB_TOKEN is required for the dry-run.")
  process.exit(2)
}
if (!config.opencodeApiKey) {
  console.error("OPENCODE_API_KEY is required to call the review model.")
  process.exit(2)
}

const octokit = new Octokit({
  auth: config.githubToken,
  baseUrl: config.githubApiUrl,
})

const { data } = await octokit.rest.pulls.get({
  owner: repo.split("/")[0]!,
  repo: repo.split("/")[1]!,
  pull_number: prNumber,
})

const diffResponse = await fetch(`${config.githubApiUrl}/repos/${repo}/pulls/${prNumber}`, {
  headers: {
    authorization: `Bearer ${config.githubToken}`,
    accept: "application/vnd.github.v3.diff",
    "x-github-api-version": "2022-11-28",
    "user-agent": "valentinvera-reviewer/0.1.0",
  },
})

if (!diffResponse.ok) {
  console.error(`Failed to fetch diff: ${diffResponse.status} ${await diffResponse.text()}`)
  process.exit(1)
}

const diff = await diffResponse.text()

if (!diff.trim()) {
  console.error("The pull request has an empty diff.")
  process.exit(1)
}

const pr: ReviewPullRequest = {
  number: data.number,
  title: data.title,
  body: data.body,
  author: data.user?.login ?? "unknown",
  baseRef: data.base.ref,
  headRef: data.head.ref,
  baseSha: data.base.sha,
  headSha: data.head.sha,
  changedFiles: data.changed_files,
  additions: data.additions,
  deletions: data.deletions,
}

const generated = await generateReview({ repo, pr, diff })

if (flags.has("--json")) {
  console.log(
    JSON.stringify(
      {
        repo,
        pr: prNumber,
        headSha: pr.headSha,
        model: generated.model,
        durationMs: generated.durationMs,
        truncated: generated.clipped.truncated,
        usage: generated.usage,
        result: generated.result,
      },
      null,
      2,
    ),
  )
  process.exit(0)
}

console.log(`\n#${pr.number} ${pr.title}`)
console.log(
  `${repo} · ${pr.headRef} -> ${pr.baseRef} · ${pr.changedFiles} files (+${pr.additions}/-${pr.deletions})`,
)
console.log(`commit ${pr.headSha.slice(0, 10)} · ${generated.model} · ${generated.durationMs}ms`)
if (generated.clipped.truncated) {
  console.log(`⚠️  diff truncated to ${config.reviewMaxDiffChars} chars`)
}

console.log(`\n${generated.result.summary}\n`)

if (generated.result.findings.length === 0) {
  console.log("No findings.")
} else {
  generated.result.findings.forEach((finding, index) => {
    console.log(
      `${index + 1}. [${finding.severity}] ${finding.path}:${finding.line} (${finding.side})`,
    )
    console.log(`   ${finding.title}`)
    console.log(`   ${finding.body.replaceAll("\n", "\n   ")}`)
    console.log()
  })
}

console.log(`\nusage: ${JSON.stringify(generated.usage ?? {})}`)
