# THE ONE CI IMAGE (epic qits-1481, "CI in a slot"). A CI run is one lease and one container, and
# this is that container: qits-ci-daemon is its entrypoint (fetched at lease start, not baked in) and
# every step of the run executes here, one after another, in a worktree under /work. So this image
# is the UNION of the step images it replaces — maven-base, node-base, node-browser-base and
# userflows-base — and every tool a recipe or a `release.yml` step calls must be in it.
# `check-tools.sh` beside this file is that list, and the `check` stage at the bottom runs it in the
# release, so a missing tool fails the release rather than somebody's build a day later.
#
# NO DOCKER CLI AND NO BUILDX, by design: steps build images through the platform buildkitd with
# `buildctl` and `$BUILDKIT_HOST`, and `docker: true` is a CONFIG_ERROR once CI runs in a slot.
# check-tools.sh asserts the absence too.
#
# Debian bookworm-slim, not Alpine: Playwright's Chromium needs glibc, and bookworm is what
# node-browser-base (the screenshot renderer) is built on.
#
# The FROM tags are LITERALS, for ci-base's reason: the SBOM generator refuses an ARG in a FROM.
# Upstream images come in as pulls, which ride the platform's registry mirror like every other
# Dockerfile in this repository.

# buildctl out of the SAME pinned image the platform's buildkitd runs — see ci-base/Dockerfile.
# Statically linked, so it runs on glibc as it does on musl.
FROM moby/buildkit:v0.33.0 AS buildkit

# Temurin JDK 25 and Maven 3.9: maven-base's `maven:3.9-eclipse-temurin-25`, the glibc variant of
# the same tag, copied rather than apt-installed (bookworm's maven is 3.8, and it has no JDK 25).
FROM maven:3.9-eclipse-temurin-25 AS maven

FROM debian:bookworm-slim AS ci-slot

ENV DEBIAN_FRONTEND=noninteractive

# The base tool set.
#
# - git: Debian ships `git daemon` and `git http-backend` inside the `git` package itself, which is
#   what Alpine's separate `git-daemon` package supplied to maven-base (see the comment there: the
#   userflow catalogues shell `git http-backend`). There is no Debian package to add for it.
# - util-linux: `setsid --ctty` for the daemon repositories' PTY suites (maven-base). Essential on
#   Debian, named anyway so nobody removes it by accident.
# - skopeo: userflows-base's, for qits-artifacts' OCI userflow stories.
# - gpg: NodeSource's setup script below needs it to add its key.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        gpg \
        jq \
        skopeo \
        util-linux \
    && rm -rf /var/lib/apt/lists/*

# Node 24 from NodeSource, exactly as node-browser-base installs it, with corepack enabled
# (node-base). pnpm is prepared at the version the estate's packageManager fields pin
# (pnpm@10.33.0), into a COREPACK_HOME any uid can read and extend: a step runs as uid 1001 with a
# HOME that may be fresh, and a per-HOME corepack cache would be re-downloaded on every run.
ENV COREPACK_HOME=/opt/corepack \
    COREPACK_ENABLE_DOWNLOAD_PROMPT=0
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && corepack enable \
    && corepack install --global pnpm@10.33.0 \
    && chmod -R a+rwX "$COREPACK_HOME" \
    && rm -rf /root/.npm /var/lib/apt/lists/*

# The JDK and Maven, from the maven stage.
ENV JAVA_HOME=/opt/java/openjdk \
    MAVEN_HOME=/usr/share/maven
ENV PATH="$JAVA_HOME/bin:$PATH"
COPY --from=maven /opt/java/openjdk /opt/java/openjdk
COPY --from=maven /usr/share/maven /usr/share/maven
RUN ln -s /usr/share/maven/bin/mvn /usr/bin/mvn \
    && java -version \
    && mvn -v

# buildctl, the client for the platform-owned buildkitd.
COPY --from=buildkit /usr/bin/buildctl /usr/local/bin/buildctl

# Fonts in their own layer, node-browser-base's exact stack: the screenshot renderer is the fonts as
# much as the Chromium, and the app QA step now renders here.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        fontconfig \
        fonts-dejavu-core \
        fonts-liberation \
        fonts-noto-core \
        fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*

# PLAYWRIGHT'S CHROMIUM, TWICE, at one fixed path any uid can read. Two consumers pin two versions,
# and Playwright only ever looks for the Chromium revision of its own version:
#
# - Node Playwright 1.63, node-browser-base's PLAYWRIGHT_VERSION — vitest browser mode and the
#   screenshot baselines. Bump in lockstep with node-browser-base and the consumers' `playwright`.
# - Playwright Java 1.61, userflows-base's `mcr.microsoft.com/playwright/java:v1.61.0` — the
#   userflow suites (qits-userflows-javalib pins com.microsoft.playwright 1.61 and launches
#   chromium only). Playwright Java X drives the Node driver of Playwright X, so
#   `playwright@1.61.0 install` fetches exactly the revisions Java 1.61 looks for.
#
# The revisions differ, so both live side by side under /ms-playwright (chromium-<rev>,
# chromium_headless_shell-<rev>). `--with-deps` installs Chromium's OS libraries.
#
# The 1.63 install's directories are noted before the 1.61 one runs, so the provenance file below
# describes the screenshot renderer and not the userflows' Chromium.
ENV PLAYWRIGHT_BROWSERS_PATH=/ms-playwright
RUN apt-get update \
    && npx -y playwright@1.63.0 install --with-deps chromium \
    && ls -d ${PLAYWRIGHT_BROWSERS_PATH}/chromium* > /tmp/playwright-1.63-dirs \
    && npx -y playwright@1.61.0 install --with-deps chromium \
    && chmod -R a+rX ${PLAYWRIGHT_BROWSERS_PATH} \
    && rm -rf /root/.npm /root/.cache /var/lib/apt/lists/*

# The renderer provenance, node-browser-base's format, for the Node 1.63 renderer: consumers'
# check-renderer scripts compare it with the copy committed beside their baselines.
RUN dirs=$(cat /tmp/playwright-1.63-dirs) \
    && { echo "playwright=1.63.0"; \
      for d in $dirs; do \
        case "$d" in \
          */chromium-*) "$d"/chrome-linux*/chrome --version | sed 's/^/chromium=/; s/ *$//' ;; \
          */chromium_headless_shell-*) echo "chromium-headless-shell=${d##*-}" ;; \
        esac; \
      done; \
      dpkg-query -W -f='${Package}=${Version}\n' fontconfig 'fonts-*' libfreetype6 libharfbuzz0b \
        | grep -v '=$' | sort; \
    } > /etc/qits-renderer-provenance \
    && grep -q '^chromium=' /etc/qits-renderer-provenance \
    && grep -q '^chromium-headless-shell=' /etc/qits-renderer-provenance \
    && chmod 0644 /etc/qits-renderer-provenance \
    && rm /tmp/playwright-1.63-dirs \
    && cat /etc/qits-renderer-provenance

# The build user, uid 1001 — the lease's `spec.user`. Passwd-backed because zonky's embedded
# postgres calls getpwuid and initdb refuses uid 0 (maven-base). HOME is under /work so it is the
# user's own; /work holds the run worktrees and /cache the warm git mirrors and package caches the
# daemon and the runner mount there. The safe.directory exemption is node-browser-base's, for a
# mirror or worktree whose owner is not the user running git.
RUN useradd --uid 1001 --user-group --home-dir /work/home --no-create-home --shell /bin/bash build \
    && mkdir -p /work/home /cache \
    && chown build:build /work /work/home /cache \
    && git config --system --add safe.directory '*'

ENV HOME=/work/home
USER build
WORKDIR /work

# THE ENTRYPOINT. The lease container starts this image with no command override — the runner's
# lease spec carries no entrypoint field — and qits-ci-service hands it the bootstrap shell script
# to run through QITS_CI_BOOTSTRAP rather than as an image argument. Exec form, no CMD: there is no
# default to fall back to, and ci-slot-entrypoint refuses outright when the variable is unset.
COPY --chmod=0755 ci-slot/ci-slot-entrypoint /usr/local/bin/ci-slot-entrypoint
ENTRYPOINT ["/usr/local/bin/ci-slot-entrypoint"]

# THE TOOL CHECK, a target of its own so the release can build it from the very stage it pushes.
# `buildctl build --opt target=check` reuses every ci-slot layer from the cache and fails when
# check-tools.sh does — before anything is pushed. Nothing exports this stage.
FROM ci-slot AS check
COPY ci-slot/check-tools.sh /tmp/check-tools.sh
RUN sh /tmp/check-tools.sh
