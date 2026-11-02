# Bun version matches .github/workflows/ci.yml.
FROM oven/bun:1.4.4 AS deps

WORKDIR /app

COPY package.json bun.lock ./

# `prepare` runs `lefthook install`. lefthook is a devDependency, so it is not
# installed with --production and the script fails the build. Drop only that
# script; dependency lifecycle scripts still run.
RUN bun -e 'const pkg = await Bun.file("package.json").json(); delete pkg.scripts.prepare; await Bun.write("package.json", JSON.stringify(pkg))' \
    && bun install --frozen-lockfile --production

FROM oven/bun:1.4.4

WORKDIR /app

ENV NODE_ENV=production

# The pinned base image ships outdated Debian packages. Apply security updates
# before copying app files so this layer stays cached across source changes.
# --with-new-pkgs installs new packages those updates require, without the
# broader package replacements of dist-upgrade. Drop apt lists to keep the
# layer small. Stay root for apt, then switch to the non-root bun user.
USER root
RUN apt-get update \
    && apt-get upgrade -y --no-install-recommends --with-new-pkgs \
    && rm -rf /var/lib/apt/lists/*

COPY --from=deps --chown=bun:bun /app/node_modules ./node_modules
COPY --chown=bun:bun package.json ./
COPY --chown=bun:bun src ./src
COPY --chown=bun:bun scripts ./scripts

RUN mkdir -p /app/data && chown bun:bun /app /app/data

USER bun

EXPOSE 3000

CMD ["bun", "run", "start"]
