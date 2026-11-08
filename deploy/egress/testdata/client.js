import dgram from "node:dgram"
import net from "node:net"

const mode = Bun.argv[2]
const target = Bun.argv[3]
const idleMs = Number(Bun.env.IDLE_MS ?? "310000")

async function finish(response) {
  const body = await response.text()
  process.stdout.write(`${response.status} ${body}\n`)
  process.exit(response.status >= 200 && response.status < 400 ? 0 : 1)
}

function bindFailure(error) {
  const code = (error && error.code) || "UNKNOWN"
  process.stderr.write(`bind-error ${code}\n`)
  if (code === "EACCES" || code === "EPERM" || code === "EADDRINUSE" || code === "EADDRNOTAVAIL") {
    process.exit(3)
  }
  process.exit(1)
}

if (mode === "https") {
  const response = await fetch(target, {
    redirect: "manual",
    signal: AbortSignal.timeout(20_000),
  })
  await finish(response)
}

if (mode === "follow") {
  const response = await fetch(target, {
    signal: AbortSignal.timeout(15_000),
  })
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
  const timer = setTimeout(() => {
    process.stderr.write("connect-error TIMEOUT\n")
    process.exit(opened ? 0 : 1)
  }, 4000)
  try {
    await Bun.connect({
      hostname: target,
      port: Number(Bun.argv[4] ?? "443"),
      socket: {
        open(sock) {
          opened = true
          clearTimeout(timer)
          process.stdout.write(`connected ${sock.localAddress ?? ""}:${sock.localPort ?? ""}\n`)
          sock.end()
          process.exit(0)
        },
        data() {},
        close() {},
        error(error) {
          process.stderr.write(`connect-error ${(error && error.code) || "UNKNOWN"}\n`)
          process.exit(1)
        },
        connectError(error) {
          process.stderr.write(`connect-error ${(error && error.code) || "UNKNOWN"}\n`)
          process.exit(1)
        },
      },
    })
  } catch (error) {
    process.stderr.write(`connect-error ${(error && error.code) || "UNKNOWN"}\n`)
    process.exit(1)
  }
}

if (mode === "dns") {
  const result = await Bun.dns.lookup(target)
  process.stdout.write(`${result[0]?.address ?? ""}\n`)
  process.exit(0)
}

if (mode === "dns-udp") {
  const name = Bun.argv[4]
  const labels = name
    .split(".")
    .filter(Boolean)
    .map((part) => Buffer.concat([Buffer.from([part.length]), Buffer.from(part)]))
  const header = Buffer.alloc(12)
  header.writeUInt16BE(0x4242, 0)
  header.writeUInt16BE(0x0100, 2)
  header.writeUInt16BE(1, 4)
  const packet = Buffer.concat([header, ...labels, Buffer.from([0, 0, 1, 0, 1])])
  const sock = dgram.createSocket("udp4")
  const result = await new Promise((resolve) => {
    const timer = setTimeout(() => resolve("TIMEOUT"), 2000)
    sock.once("error", (error) => {
      clearTimeout(timer)
      resolve(`ERROR ${(error && error.code) || "UNKNOWN"}`)
    })
    sock.once("message", (msg) => {
      clearTimeout(timer)
      if (msg.length < 12) {
        resolve("SHORT")
        return
      }
      const rcode = msg.readUInt16BE(2) & 0xf
      const answers = msg.readUInt16BE(6)
      resolve(answers > 0 ? `ANSWER rcode=${rcode} ancount=${answers}` : `NOANSWER rcode=${rcode}`)
    })
    sock.send(packet, 53, target, (error) => {
      if (error) {
        clearTimeout(timer)
        resolve(`ERROR ${(error && error.code) || "UNKNOWN"}`)
      }
    })
  })
  sock.close()
  process.stdout.write(`${result}\n`)
  process.exit(result.startsWith("ANSWER") ? 0 : 1)
}

if (mode === "udp") {
  const port = Number(Bun.argv[4])
  const sock = dgram.createSocket("udp4")
  const result = await new Promise((resolve) => {
    const timer = setTimeout(() => resolve("none"), 1000)
    sock.once("error", (error) => {
      clearTimeout(timer)
      resolve(`ERROR ${(error && error.code) || "UNKNOWN"}`)
    })
    sock.once("message", () => {
      clearTimeout(timer)
      resolve("reply")
    })
    sock.send(Buffer.from("probe"), port, target, (error) => {
      if (error) {
        clearTimeout(timer)
        resolve(`ERROR ${(error && error.code) || "UNKNOWN"}`)
      }
    })
  })
  sock.close()
  process.stdout.write(`${result}\n`)
  process.exit(result === "reply" ? 0 : 1)
}

if (mode === "route-ip") {
  const sock = dgram.createSocket("udp4")
  sock.connect(Number(Bun.argv[4] ?? "9"), target)
  process.stdout.write(`${sock.address().address}\n`)
  sock.close()
  process.exit(0)
}

if (mode === "bind") {
  await new Promise(() => {
    const port = Number(Bun.argv[4])
    const localPort = Number(Bun.argv[5])
    const localAddress = Bun.argv[6]
    const socket = net.connect({
      host: target,
      port,
      localPort,
      localAddress: localAddress || undefined,
    })
    const timer = setTimeout(() => {
      socket.destroy()
      process.stderr.write("bind-error TIMEOUT\n")
      process.exit(1)
    }, 3000)
    socket.once("connect", () => {
      clearTimeout(timer)
      process.stdout.write(`connected ${socket.localAddress}:${socket.localPort}\n`)
      socket.destroy()
      process.exit(0)
    })
    socket.once("error", (error) => {
      clearTimeout(timer)
      bindFailure(error)
    })
  })
}

if (mode === "bind-proof") {
  const localPort = Number(Bun.argv[3])
  const localAddress = Bun.argv[4]
  const listener = net.createServer((sock) => sock.end())
  try {
    await new Promise((resolve, reject) => {
      listener.once("error", reject)
      listener.listen(0, localAddress, resolve)
    })
  } catch (error) {
    process.stderr.write(`bind-error ${(error && error.code) || "UNKNOWN"}\n`)
    process.exit(4)
  }
  const destPort = listener.address().port
  await new Promise(() => {
    const socket = net.connect({ host: localAddress, port: destPort, localAddress, localPort })
    const timer = setTimeout(() => {
      socket.destroy()
      listener.close()
      process.stderr.write("bind-error TIMEOUT\n")
      process.exit(1)
    }, 3000)
    socket.once("connect", () => {
      clearTimeout(timer)
      const seen = `${socket.localAddress}:${socket.localPort}`
      const matched = socket.localPort === localPort
      process.stdout.write(`connected ${seen}\n`)
      socket.destroy()
      listener.close()
      process.exit(matched ? 0 : 4)
    })
    socket.once("error", (error) => {
      clearTimeout(timer)
      listener.close()
      bindFailure(error)
    })
  })
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
