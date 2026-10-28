import { generateKeyPairSync } from "node:crypto"

// Keep tests away from the real SQLite file.
process.env.DATABASE_PATH = ":memory:"
process.env.LOG_LEVEL = "error"

// Dummy GitHub App credentials for webhook tests. The key is generated at
// runtime and never leaves the test process.
const { privateKey } = generateKeyPairSync("rsa", {
  modulusLength: 2048,
  privateKeyEncoding: { type: "pkcs8", format: "pem" },
  publicKeyEncoding: { type: "spki", format: "pem" },
})

process.env.GITHUB_APP_ID = "123"
process.env.GITHUB_PRIVATE_KEY = privateKey.toString()
process.env.GITHUB_WEBHOOK_SECRET = "test-secret"
