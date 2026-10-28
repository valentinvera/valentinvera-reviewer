import { config } from "../config"
import { getGitHubApp } from "./app"

/**
 * The configured @octokit/webhooks instance, owned by @octokit/app.
 *
 * `app.webhooks` is created when the App is constructed with
 * `webhooks: { secret }`; this helper validates that the secret exists and
 * returns that instance so there is a single source of truth.
 *
 * Handlers receive `{ id, name, payload, octokit }`. The injected `octokit` is
 * App-level (JWT); for repository operations resolve the installation first:
 *
 *   const octokit = await getGitHubApp().getInstallationOctokit(
 *     payload.installation!.id,
 *   )
 */
export function getWebhooks() {
  if (!config.githubWebhookSecret) {
    throw new Error("GitHub webhooks are not configured: set GITHUB_WEBHOOK_SECRET")
  }

  return getGitHubApp().webhooks
}
