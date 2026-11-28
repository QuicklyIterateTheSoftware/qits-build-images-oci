FROM debian:bookworm-slim AS node-browser-base

# THE SCREENSHOT RENDERER, IN ONE PLACE. Browser screenshot tests (vitest browser mode with
# Playwright Chromium, `toMatchScreenshot`) only match their committed baselines when they run on
# the same Chromium build, the same fonts and the same OS libraries that rendered them. Two places
# render them: CI's QA step (the `app` archetype runs `npm run --if-present test:browser` on this
# image) and an agent's workspace (qits-workspace-oci builds `qits/workspace-base` FROM this image).
# Both use this one stack, so a baseline made in either matches in the other. Nothing about the
# renderer is installed anywhere else.
#
# `/etc/qits-renderer-provenance` records the stack: the Playwright version, the Chromium builds and
# every font package with its exact version. A consumer commits a copy beside its baselines and
# compares it before a run, so a renderer that moved fails with "regenerate the baselines" instead
# of a page of pixel diffs.
#
# Debian bookworm, not Playwright's Ubuntu image: the workspace image is built on bookworm and keeps
# its own apt layers on top of this one.

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        gpg \
        jq \
    && rm -rf /var/lib/apt/lists/*

# Node 24, the major node-base runs on. NodeSource's repository, as the workspace image had it.
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && corepack enable \
    && rm -rf /var/lib/apt/lists/*

# Fonts in their own layer, because they almost never change: fontconfig and DejaVu (Chromium's
# default Linux sans-serif fallback), Liberation (metric-compatible Arial, Helvetica and Times),
# Noto core and color emoji (so a stray glyph renders the same everywhere).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        fontconfig \
        fonts-dejavu-core \
        fonts-liberation \
        fonts-noto-core \
        fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*

# Playwright's Chromium, at a fixed path any uid can read: CI steps run as root, workspaces as an
# arbitrary uid with HOME=/workspace, so a per-HOME cache would serve neither.
#
# PLAYWRIGHT_VERSION MUST EQUAL the `playwright` version a consumer's lockfile resolves, because
# Playwright looks for the Chromium revision of its own version. Consumers pin `playwright` exactly
# to this value. Bumping it is a re-record event: bump here, release, then bump the consumers'
# `playwright` and regenerate their baselines in this image. A consumer ahead of the image fails with
# "Executable doesn't exist at /opt/ms-playwright/…", which means "release this image", never
# "playwright install" locally. `--with-deps` installs Chromium's libraries and supplemental fonts.
ARG PLAYWRIGHT_VERSION=1.63.0
ENV PLAYWRIGHT_BROWSERS_PATH=/opt/ms-playwright
RUN apt-get update \
    && npx -y playwright@${PLAYWRIGHT_VERSION} install --with-deps chromium \
    && chmod -R a+rX ${PLAYWRIGHT_BROWSERS_PATH} \
    && rm -rf /root/.npm /var/lib/apt/lists/*

# The provenance file. A file rather than a LABEL, because a test inside a container can read a
# file and cannot read its own image's labels. The 'fonts-*' glob also catches the fonts
# --with-deps pulled in. The greps fail the build when a Chromium line is missing, so a Playwright
# layout change cannot leave the record silently incomplete.
RUN { echo "playwright=${PLAYWRIGHT_VERSION}"; \
      ${PLAYWRIGHT_BROWSERS_PATH}/chromium-*/chrome-linux*/chrome --version | sed 's/^/chromium=/; s/ *$//'; \
      for d in ${PLAYWRIGHT_BROWSERS_PATH}/chromium_headless_shell-*; do \
        [ -d "$d" ] && echo "chromium-headless-shell=${d##*-}"; \
      done; \
      dpkg-query -W -f='${Package}=${Version}\n' fontconfig 'fonts-*' libfreetype6 libharfbuzz0b \
        | grep -v '=$' | sort; \
    } > /etc/qits-renderer-provenance \
    && grep -q '^chromium=' /etc/qits-renderer-provenance \
    && grep -q '^chromium-headless-shell=' /etc/qits-renderer-provenance \
    && chmod 0644 /etc/qits-renderer-provenance \
    && cat /etc/qits-renderer-provenance

# The step-image contract (see maven-base and userflows-base): /workspace sticky and world-writable,
# because qits-ci-daemon clones into it and steps run cap-dropped; and git's safe.directory
# exemption, because the clone's owner is not always the user running git.
RUN mkdir -p /workspace \
    && chmod 1777 /workspace \
    && git config --system --add safe.directory '*'

# THE IMAGE TRUST HOOK (epic qits-2524; trust/ and the README's "Platform trust anchors"). The build
# points the system bundle at /etc/ssl/qits/ca-bundle.pem (directory 0777, files 0666), seeded with
# this image's public trust, and installs qits-trust-init, which rewrites it from QITS_TRUST_ANCHORS
# at container start under any uid. This image has no ENTRYPOINT of its own: the images built on it
# (qits/workspace-base and the daemon images on top) start through qits-trust-init, and
# workspace-base runs qits-trust-layout again once it has installed its JDK. The ENV covers the tools
# that read a bundle path of their own. Last, after every apt layer, any of which may rewrite the
# bundle.
COPY --chmod=0755 trust/qits-trust-layout trust/qits-trust-init /usr/local/bin/
RUN qits-trust-layout
# THE WORKLOAD CERTIFICATE HOOK (epic qits-2626, qits-2762): sourced by qits-trust-init at start, it
# runs `qits certificate keep` in the background when the container holds QITS_TOKEN and a qits CLI
# (the agent, desk and workspace images put both in), and does nothing otherwise. The layout above
# made /run/qits 1777 for it.
COPY --chmod=0644 trust/40-workload-certificate.sh /etc/qits/init.d/40-workload-certificate.sh
# COPY --chmod gives the directories it creates the file's mode too (0644: no x), and a non-root
# qits-trust-init could then list the hook but not open it, so the hook never ran. 0755 restores them.
RUN chmod 0755 /etc/qits /etc/qits/init.d
ENV NODE_EXTRA_CA_CERTS=/etc/ssl/qits/ca-bundle.pem \
    REQUESTS_CA_BUNDLE=/etc/ssl/qits/ca-bundle.pem \
    PIP_CERT=/etc/ssl/qits/ca-bundle.pem \
    SSL_CERT_FILE=/etc/ssl/qits/ca-bundle.pem \
    CURL_CA_BUNDLE=/etc/ssl/qits/ca-bundle.pem \
    GIT_SSL_CAINFO=/etc/ssl/qits/ca-bundle.pem

# THE TRUST TEST, a target of its own like ci-slot's `check`: the release builds it from the stage it
# pushes, before anything is pushed, and nothing exports it. Run as `nobody`, because the init must
# work without root: it asserts the layout and the ENV, then has curl, git and node trust a throwaway
# CA served by openssl s_server once qits-trust-init installed it. No python3 and no JDK here, so
# those probes report `skip`.
FROM node-browser-base AS check
COPY trust/test-trust.sh /tmp/test-trust.sh
USER nobody
RUN sh /tmp/test-trust.sh --installed

# THE IMAGE IS THE LAST STAGE, unchanged: a build that names no target — the release's loop, the
# README's, and qits-bootstrap's seed build of this file — gets node-browser-base itself, and
# BuildKit never builds `check` for it.
FROM node-browser-base
