import { describe, expect, test } from "bun:test"
import { db } from "../src/db"

describe("migrations", () => {
  test("applies the initial migration once", () => {
    const versions = db
      .query<{ version: string }, []>("SELECT version FROM schema_migrations ORDER BY version")
      .all()

    expect(versions.map((row) => row.version)).toContain("001_initial")
    expect(versions.map((row) => row.version)).toContain("002_review_state")
  })
})
