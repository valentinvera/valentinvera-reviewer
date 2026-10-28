import { createOpenAICompatible } from "@ai-sdk/openai-compatible"
import { config, type ReasoningMode } from "./config"

export const REVIEW_USER_AGENT = "valentinvera-reviewer/0.1.0"

/**
 * Applies the reasoning policy to an OpenAI-compatible request body.
 * Exported so it can be verified without hitting the network.
 */
export function applyReasoningPolicy(body: string, mode: ReasoningMode): string {
  if (!body) return body

  try {
    const payload = JSON.parse(body) as Record<string, unknown>

    if (mode === "off") {
      delete payload.reasoning_effort
      payload.reasoning = { enabled: false }
    } else {
      delete payload.reasoning
      payload.reasoning_effort = mode
    }

    return JSON.stringify(payload)
  } catch {
    // Not JSON: leave the request untouched.
    return body
  }
}

/**
 * OpenCode Go needs a stable session header. DeepSeek V4.1 Flash is also a
 * reasoning model: with a full diff it can spend the whole output budget
 * thinking and return no text, so the policy is injected here.
 */
const rewriteProviderRequest = async (
  input: Parameters<typeof fetch>[0],
  init?: Parameters<typeof fetch>[1],
): Promise<Response> => {
  const headers = new Headers(init?.headers)
  headers.set("user-agent", REVIEW_USER_AGENT)
  if (config.aiSessionId) headers.set("x-opencode-session", config.aiSessionId)

  let body = init?.body

  if (typeof body === "string" && body.length > 0) {
    body = applyReasoningPolicy(body, config.aiReasoningMode)
  }

  return fetch(input, { ...init, headers, body })
}

// Bun's `fetch` type has a static `preconnect`; the AI SDK only needs the call
// signature, so the assertion keeps both sides happy.
const providerFetch = rewriteProviderRequest as unknown as typeof fetch

/**
 * OpenCode Go exposes an OpenAI-compatible endpoint:
 * https://opencode.ai/inference/go/openai/v1
 */
export function createReviewModel() {
  if (!config.opencodeApiKey) {
    throw new Error("OPENCODE_API_KEY is not set")
  }

  const provider = createOpenAICompatible({
    name: "opencode-go",
    baseURL: config.aiBaseUrl,
    apiKey: config.opencodeApiKey,
    supportsStructuredOutputs: true,
    fetch: providerFetch,
    headers: {
      "user-agent": REVIEW_USER_AGENT,
      "x-opencode-session": config.aiSessionId,
    },
  })

  return provider(config.aiModel)
}
