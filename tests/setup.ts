// Keep tests away from the real SQLite file.
process.env.DATABASE_PATH = ":memory:"
process.env.LOG_LEVEL = "error"
