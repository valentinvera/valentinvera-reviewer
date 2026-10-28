import { log } from "../logger"
import { registerJobHandler } from "./index"

/**
 * Demo handler that proves the queue works end to end.
 * Replace/extend with the real `review_pull_request` handler later.
 */
registerJobHandler("demo", async (job) => {
  log.info("demo.start", { id: job.id, payload: job.payload })

  await Bun.sleep(500)
})
