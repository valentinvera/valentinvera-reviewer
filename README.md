# valentinvera-reviewer

GitHub App that reviews pull requests.

## Stack

Bun · `Bun.serve()` · SQLite (`bun:sqlite`) · `@octokit/app` · `@octokit/webhooks` · Vercel AI SDK Core · OpenCode Go (`deepseek-v4.1-flash`).

## GitHub App permissions

Grant at least:

| Permission    | Access       | Why                                                         |
| ------------- | ------------ | ----------------------------------------------------------- |
| Pull requests | Read & write | Read diffs, publish review comments / suggestions           |
| Checks        | **Write**    | Create the `valentinvera-reviewer` check run                |
| Contents      | Read         | Read `.reviewer/rules.md` and `AGENTS.md` from the base ref |
| Issues        | Read & write | Summary / failure comments on the PR                        |
| Metadata      | Read         | Required by GitHub Apps                                     |

Subscribe to webhook events: `pull_request`, `issue_comment`, `pull_request_review_comment`, `ping`.

After changing permissions, accept the new permissions on each installation.

## Behaviour notes

- Draft PRs are skipped silently for automatic events (no comment, no check). Marking a PR ready (`ready_for_review`) triggers a full first review. Explicit `/review` still runs on drafts.
- On `synchronize`, only the diff since the last successfully reviewed SHA is reviewed (compare API), with a full-diff fallback on force-push / unknown base.
- Check run name defaults to `valentinvera-reviewer` (`REVIEW_CHECK_NAME`).
- Automatic reviews per PR are capped by `REVIEW_AUTO_MAX_ROUNDS` (default `5`); `/review` still works after the cap.
- Optional repo rules: `.reviewer/rules.md` and `AGENTS.md` on the PR base ref.
- Dismiss a finding by replying `not an issue` / `no es un issue` / `false positive` (or 👎); the thread is resolved and remembered per repo.
