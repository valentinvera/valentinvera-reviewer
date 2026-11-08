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
# before copying app files. --with-new-pkgs installs packages those updates
# require, without the broader replacements of dist-upgrade. Drop apt lists to
# keep the layer small. Stay root for apt, then switch to the non-root bun user.
#
# BuildKit reuses a RUN layer while its command is unchanged, and the deploy
# workflow restores that cache (mode=max). The upgrade would stay frozen, so
# production would keep CVEs that a clean rebuild no longer has.
# OS_SECURITY_REVISION is part of this layer's cache key and must change on
# every build; the workflows pass the run id and attempt. An empty value fails
# the build, so omitting it cannot reuse a stale upgrade. The deps stage does
# not use this argument, so its install cache stays valid.
USER root
ARG OS_SECURITY_REVISION
RUN if [ -z "${OS_SECURITY_REVISION}" ]; then \
      echo "OS_SECURITY_REVISION is required so the OS upgrade is not reused from cache." >&2; \
      exit 1; \
    fi \
    && echo "os-security-revision=${OS_SECURITY_REVISION}" \
    && export DEBIAN_FRONTEND=noninteractive \
    && apt-get update \
    && apt-get upgrade -y --no-install-recommends --with-new-pkgs \
    && rm -rf /var/lib/apt/lists/*

COPY --from=deps --chown=bun:bun /app/node_modules ./node_modules
COPY --chown=bun:bun package.json ./
COPY --chown=bun:bun src ./src
COPY --chown=bun:bun scripts ./scripts
COPY deploy/egress/app-entrypoint.sh /usr/local/bin/app-entrypoint.sh

RUN mkdir -p /app/data && chown bun:bun /app /app/data \
    && chmod 0555 /usr/local/bin/app-entrypoint.sh

USER bun

EXPOSE 3000

# EGRESS_REQUIRED is unset here, so existing direct-network starts keep working.
ENTRYPOINT ["/usr/local/bin/app-entrypoint.sh"]
CMD ["bun", "run", "start"]
