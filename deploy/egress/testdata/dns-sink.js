import dgram from "node:dgram"
import fs from "node:fs"
import net from "node:net"

const port = Number(Bun.env.DNS_PORT ?? "53")
const logPath = Bun.env.DNS_LOG ?? "/log/queries"
const canary = "canary.stage.test"
const canaryIp = Bun.env.CANARY_IP ?? "192.0.2.55"

function qname(buf) {
  const labels = []
  let pos = 12
  while (pos < buf.length) {
    const len = buf[pos]
    if (len === 0 || (len & 0xc0) === 0xc0) break
    labels.push(buf.subarray(pos + 1, pos + 1 + len).toString("utf8"))
    pos += 1 + len
  }
  return labels.join(".").toLowerCase()
}

function respond(query) {
  const name = qname(query)
  fs.appendFileSync(logPath, `${name}\n`)
  const header = Buffer.from(query.subarray(0, 12))
  const question = query.subarray(12)
  const refused = name !== canary
  header.writeUInt16BE(0x8400 | (refused ? 5 : 0), 2)
  header.writeUInt16BE(0, 8)
  header.writeUInt16BE(0, 10)
  if (refused) {
    header.writeUInt16BE(0, 6)
    return Buffer.concat([header, question])
  }
  header.writeUInt16BE(1, 6)
  const rr = Buffer.alloc(16)
  rr.writeUInt16BE(0xc00c, 0)
  rr.writeUInt16BE(1, 2)
  rr.writeUInt16BE(1, 4)
  rr.writeUInt32BE(30, 6)
  rr.writeUInt16BE(4, 10)
  const parts = canaryIp.split(".").map((part) => Number(part))
  rr.set(parts, 12)
  return Buffer.concat([header, question, rr])
}

const udp = dgram.createSocket("udp4")
udp.on("message", (msg, rinfo) => {
  udp.send(respond(msg), rinfo.port, rinfo.address)
})
udp.bind(port, "0.0.0.0")

const tcp = net.createServer((socket) => {
  const chunks = []
  socket.on("data", (chunk) => {
    chunks.push(chunk)
    const buf = Buffer.concat(chunks)
    if (buf.length < 2) return
    const length = buf.readUInt16BE(0)
    if (buf.length < 2 + length) return
    const response = respond(buf.subarray(2, 2 + length))
    const framed = Buffer.alloc(2 + response.length)
    framed.writeUInt16BE(response.length, 0)
    response.copy(framed, 2)
    socket.end(framed)
  })
})
tcp.listen(port, "0.0.0.0")
