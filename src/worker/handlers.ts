import { log } from "../logger"
import { reportFinalReviewFailure } from "../review/failure"
import { processReviewJob, type ReviewJobPayload } from "../review/handler"
import { registerFinalFailureHandler, registerJobHandler } from "./index"

/**
 * Demo handler that proves the queue works end to end.
 */
registerJobHandler("demo", async (job) => {
  log.info("demo.start", { id: job.id, payload: job.payload })

  await Bun.sleep(500)
})

registerJobHandler("review_pull_request", async (job) => {
  await processReviewJob(job.payload as ReviewJobPayload)
})

registerFinalFailureHandler("review_pull_request", async (job, error) => {
  await reportFinalReviewFailure(job.payload as ReviewJobPayload, error)
})
