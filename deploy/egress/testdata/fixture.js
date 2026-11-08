Bun.serve({
  port: 8443,
  hostname: "0.0.0.0",
  tls: {
    cert: await Bun.file("/certs/srv.crt").text(),
    key: await Bun.file("/certs/srv.key").text(),
  },
  async fetch(request) {
    const path = new URL(request.url).pathname
    if (path === "/slow") {
      const raw = await Bun.file("/delay/ms")
        .text()
        .catch(() => "0")
      await Bun.sleep(Number(raw.trim() || "0"))
      return new Response("slow-ok")
    }
    if (path === "/redir") {
      return new Response(null, {
        status: 302,
        headers: { Location: "https://blocked.fixture:8443/nope" },
      })
    }
    return new Response("ok")
  },
})
