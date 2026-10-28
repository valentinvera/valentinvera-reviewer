import { enqueueJob } from "../src/queue"

const at = new Date().toISOString()

const queued = enqueueJob({
  deliveryId: `demo-${crypto.randomUUID()}`,
  kind: "demo",
  payload: {
    message: "hello from queue-demo",
    at,
  },
})

if (queued) {
  console.log(`queued demo job at ${at}`)
} else {
  console.log("duplicate delivery: job was not enqueued")
}
