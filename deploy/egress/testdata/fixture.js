const certPath = Bun.env.FIXTURE_CERT ?? "/certs/srv.crt"
const keyPath = Bun.env.FIXTURE_KEY ?? "/certs/srv.key"
const delayPath = Bun.env.FIXTURE_DELAY ?? "/delay/ms"
const port = Number(Bun.env.FIXTURE_PORT ?? "8443")

// Bun rejects any idleTimeout above 255 seconds, so a non-zero value cannot
// cover the 310s quiet proof. Zero disables this server's idle timer. The
// client abort and the harness timeout stay finite and above 310 seconds.
Bun.serve({
  port,
  hostname: "0.0.0.0",
  idleTimeout: 0,
  tls: {
    cert: await Bun.file(certPath).text(),
    key: await Bun.file(keyPath).text(),
  },
  async fetch(request) {
    const path = new URL(request.url).pathname
    if (path === "/slow") {
      const raw = await Bun.file(delayPath)
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
