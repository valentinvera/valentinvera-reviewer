import { describe, expect, test } from "bun:test"
import { applyReasoningPolicy } from "../src/ai"

const BODY = JSON.stringify({
  model: "deepseek-v4.1-flash",
  messages: [{ role: "user", content: "hi" }],
  max_tokens: 1000,
})

describe("applyReasoningPolicy", () => {
  test("disables reasoning when mode is off", () => {
    const payload = JSON.parse(applyReasoningPolicy(BODY, "off")) as Record<string, unknown>

    expect(payload.reasoning).toEqual({ enabled: false })
    expect(payload.reasoning_effort).toBeUndefined()
    expect(payload.model).toBe("deepseek-v4.1-flash")
  })

  test("sets reasoning_effort for enabled modes", () => {
    const payload = JSON.parse(applyReasoningPolicy(BODY, "low")) as Record<string, unknown>

    expect(payload.reasoning_effort).toBe("low")
    expect(payload.reasoning).toBeUndefined()
  })

  test("removes a stale reasoning_effort when disabling", () => {
    const withEffort = JSON.stringify({ ...JSON.parse(BODY), reasoning_effort: "high" })
    const payload = JSON.parse(applyReasoningPolicy(withEffort, "off")) as Record<string, unknown>

    expect(payload.reasoning_effort).toBeUndefined()
    expect(payload.reasoning).toEqual({ enabled: false })
  })

  test("returns non-JSON bodies untouched", () => {
    expect(applyReasoningPolicy("not-json", "off")).toBe("not-json")
    expect(applyReasoningPolicy("", "off")).toBe("")
  })
})
