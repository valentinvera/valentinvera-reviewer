const port = Number(Bun.env.HEALTH_PORT ?? "8080")
const hostname = Bun.env.HEALTH_BIND ?? "0.0.0.0"
const controlPath = Bun.env.HEALTH_CONTROL ?? "/tmp/health.control"
const statePath = Bun.env.HEALTH_STATE ?? "/tmp/health.state"

let server = null

function listen() {
  server = Bun.serve({
    port,
    hostname,
    fetch() {
      return new Response("ok")
    },
  })
  return Bun.write(statePath, "listening\n")
}

function release() {
  server.stop(true)
  server = null
  return Bun.write(statePath, "released\n")
}

await listen()
setInterval(async () => {
  const want = await Bun.file(controlPath)
    .text()
    .then((text) => text.trim())
    .catch(() => "")
  if (want === "release" && server) await release()
  if (want === "listen" && !server) await listen()
}, 100)
