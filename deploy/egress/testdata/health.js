Bun.serve({
  port: 8080,
  hostname: "0.0.0.0",
  fetch() {
    return new Response("ok")
  },
})
