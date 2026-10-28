import { createPrivateKey } from "node:crypto"
import { App } from "@octokit/app"
import { Octokit } from "octokit"
import { config } from "../config"

/**
 * GitHub can hand out App private keys in PKCS#1
 * (`-----BEGIN RSA PRIVATE KEY-----`). Octokit expects PKCS#8, so normalize it
 * once here instead of failing at the first API call.
 */
function normalizePrivateKey(pem: string): string {
  if (pem.includes("BEGIN PRIVATE KEY")) return pem
  return createPrivateKey(pem).export({ type: "pkcs8", format: "pem" }).toString()
}

let app: App | undefined

/**
 * Configured GitHub App instance.
 *
 * - Auth/JWT/installation tokens: handled by @octokit/app.
 * - REST methods: provided by the `octokit` package (`octokit.rest.*`).
 *
 * Usage:
 *   const octokit = await getGitHubApp().getInstallationOctokit(installationId)
 *   await octokit.rest.pulls.createReview({ ... })
 */
export function getGitHubApp(): App {
  if (!config.githubAppId || !config.githubPrivateKey) {
    throw new Error("GitHub App is not configured: set GITHUB_APP_ID and GITHUB_PRIVATE_KEY_PATH")
  }

  app ??= new App({
    appId: config.githubAppId,
    privateKey: normalizePrivateKey(config.githubPrivateKey),
    Octokit: Octokit.defaults({ baseUrl: config.githubApiUrl }),
    // `app.webhooks` is a @octokit/webhooks instance. It only exists when the
    // secret is provided; getWebhooks() validates that before returning it.
    ...(config.githubWebhookSecret ? { webhooks: { secret: config.githubWebhookSecret } } : {}),
  })

  return app
}
