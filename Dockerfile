# Bun version matches .github/workflows/ci.yml.
FROM oven/bun:1.4.0 AS deps

WORKDIR /app

COPY package.json bun.lock ./

# `prepare` runs `lefthook install`. lefthook is a devDependency, so it is not
# installed with --production and the script fails the build. Drop only that
# script; dependency lifecycle scripts still run.
RUN bun -e 'const pkg = await Bun.file("package.json").json(); delete pkg.scripts.prepare; await Bun.write("package.json", JSON.stringify(pkg))' \
    && bun install --frozen-lockfile --production

FROM oven/bun:1.4.0

WORKDIR /app

ENV NODE_ENV=production

COPY --from=deps --chown=bun:bun /app/node_modules ./node_modules
COPY --chown=bun:bun package.json ./
COPY --chown=bun:bun src ./src
COPY --chown=bun:bun scripts ./scripts

RUN mkdir -p /app/data && chown bun:bun /app /app/data

USER bun

EXPOSE 3000

CMD ["bun", "run", "start"]
