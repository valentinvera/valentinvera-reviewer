const mode = Bun.argv[2]
const target = Bun.argv[3]
const idleMs = Number(Bun.env.IDLE_MS ?? "310000")

async function finish(response) {
  const body = await response.text()
  process.stdout.write(`${response.status} ${body}\n`)
  process.exit(response.status >= 200 && response.status < 400 ? 0 : 1)
}

if (mode === "https") {
  const response = await fetch(target, {
    redirect: "manual",
    signal: AbortSignal.timeout(20_000),
  })
  await finish(response)
}

if (mode === "follow") {
  const response = await fetch(target)
  await finish(response)
}

if (mode === "idle") {
  const response = await fetch(target, {
    signal: AbortSignal.timeout(idleMs + 30_000),
    timeout: false,
  })
  await finish(response)
}

if (mode === "direct") {
  let opened = false
  const timer = setTimeout(() => process.exit(opened ? 0 : 1), 4000)
  try {
    await Bun.connect({
      hostname: target,
      port: Number(Bun.argv[4] ?? "443"),
      socket: {
        open(sock) {
          opened = true
          clearTimeout(timer)
          sock.end()
          process.exit(0)
        },
        data() {},
        close() {},
        error() {
          process.exit(1)
        },
        connectError() {
          process.exit(1)
        },
      },
    })
  } catch {
    process.exit(1)
  }
}

if (mode === "dns") {
  const result = await Bun.dns.lookup(target)
  process.stdout.write(`${result[0]?.address ?? ""}\n`)
}

if (mode === "proxy-false") {
  const response = await fetch(target, {
    proxy: false,
    redirect: "manual",
    signal: AbortSignal.timeout(8000),
  })
  await finish(response)
}

process.exit(2)
