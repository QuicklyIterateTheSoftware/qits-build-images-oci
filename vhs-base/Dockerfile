# THE TAPE PLAYER. This image plays `tapes/*.tape` for the `cli-tapes` kind: the `cli-tapes`
# archetype's QA step runs `vhs` against each tape and diffs the plain-text transcript it writes
# against a committed golden, and qits-maintenance's `cli-tapes` automation runs the same tapes to
# regenerate the GIFs a repository's README embeds. One image, because both consumers must render
# a tape identically — the text golden and the GIF come out of the same vhs/ttyd/Chromium/font
# stack, exactly as node-browser-base is the one renderer behind both the `app` QA step and the
# workspace image.
#
# WHAT EACH TOOL IS FOR:
#
# - vhs (charmbracelet/vhs): reads a `.tape` script and drives a terminal session, emitting the
#   plain-text transcript (what QA diffs) and, when the tape says `Output *.gif`, the GIF (what the
#   automation publishes). It is the whole point of the image.
# - ttyd: the pty-over-websocket bridge vhs launches and drives a browser against. vhs does not
#   spawn a terminal itself; it shells out to ttyd and then screenshots/records the page ttyd serves.
# - chromium + ffmpeg: vhs drives ttyd's page through a headless Chrome (go-rod) to capture frames,
#   and shells out to ffmpeg to encode those frames into the GIF. Debian's `chromium` package puts
#   the binary on PATH as `chromium`, which is one of the names vhs/go-rod looks for; no extra env
#   is needed for discovery. `VHS_NO_SANDBOX=true` is set because vhs (like Playwright) runs
#   Chromium as root here, and Chromium refuses its own sandbox under root — vhs reads this
#   variable and adds `--no-sandbox` itself.
# - the font set: node-browser-base's exact packages (fontconfig, DejaVu, Liberation, Noto core and
#   color emoji), so a tape's text renders with the same metrics and glyphs everywhere a tape is
#   ever played. A tape is a pixel-for-pixel GIF and a character-for-character transcript; a
#   font substitution changes both silently.
# - bash, git, jq, ca-certificates, curl: qits-ci's automation prelude reads its payload with `jq`
#   and refuses an image that lacks it (see qits-maintenance's automation runner); the rest is the
#   baseline every step image on this estate carries.
# - buildctl: `tapes/prepare.sh`, which a repository runs before its tapes, builds that repository's
#   CLI as a native binary (so the tape records a real process, not a JVM start-up) through the
#   platform's own buildkitd rather than a local docker. Copied from the SAME pinned moby/buildkit
#   image ci-base/Dockerfile copies it from — see the comment there; the tag moves with ci-base's,
#   not on its own.
# - the headless JRE: the CLI's tape fixtures run against a FAKE platform, `FakePlatformMain`, which
#   is a small Java program (so a tape can run in CI without the real platform behind it); Java is
#   not otherwise part of rendering a tape. Bookworm carries no JRE 25 package, so it comes from a
#   pinned Temurin image stage below, the same way ci-slot takes its JDK from a pinned `maven` stage
#   rather than an apt package.
#
# BUMPING vhs, ttyd, chromium OR THE FONTS IS A RE-RECORD EVENT, node-browser-base's rule applied
# here: any of the four can move a pixel or a character, so every committed golden transcript and
# every published GIF across every repository with tapes must be regenerated against the new image
# before it ships, never assumed to still match.
#
# Debian bookworm-slim, not an upstream vhs/ttyd image: there is no single upstream image that
# carries vhs, ttyd and a matching Chromium together, and bookworm is what node-browser-base and
# ci-slot already standardise the estate's rendering on.

# buildctl out of the SAME pinned image ci-base copies it from — see ci-base/Dockerfile.
FROM moby/buildkit:v0.33.0 AS buildkit

# The headless JRE only: FakePlatformMain is run, never compiled, in this image, so the JRE variant
# is enough — unlike maven-base/ci-slot, which copy the JDK variant because they also build with it.
FROM eclipse-temurin:25-jre AS jre

FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        bash \
        ca-certificates \
        curl \
        git \
        jq \
    && rm -rf /var/lib/apt/lists/*

# Fonts in their own layer, node-browser-base's exact stack (see the header comment for why these
# five and not more).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        fontconfig \
        fonts-dejavu-core \
        fonts-liberation \
        fonts-noto-core \
        fonts-noto-color-emoji \
    && rm -rf /var/lib/apt/lists/*

# ffmpeg (vhs shells out to it to encode a tape's frames into a GIF) and Chromium (vhs/go-rod's
# headless browser, bookworm's `chromium` package, binary on PATH as `chromium`).
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        chromium \
        ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# vhs runs Chromium as root in this image and Chromium's own sandbox refuses that; this is the
# variable vhs reads to add `--no-sandbox` itself instead of failing.
ENV VHS_NO_SANDBOX=true

# vhs, from its GitHub release's linux .deb. Its goreleaser-built .deb names use the same amd64/
# arm64 spelling as TARGETARCH, so no translation table is needed here, unlike ttyd below.
ARG VHS_VERSION=0.12.1
ARG TARGETARCH
RUN set -eu; \
    case "${TARGETARCH}" in \
        amd64|arm64) ;; \
        *) echo "vhs-base: no known vhs release asset for TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/vhs.deb \
        "https://github.com/charmbracelet/vhs/releases/download/v${VHS_VERSION}/vhs_${VHS_VERSION}_${TARGETARCH}.deb" \
    && apt-get update \
    && apt-get install -y --no-install-recommends /tmp/vhs.deb \
    && rm -f /tmp/vhs.deb \
    && rm -rf /var/lib/apt/lists/*

# ttyd, the static binary from its GitHub release — tsl0922/ttyd publishes one per arch, named by
# the `uname -m` spelling rather than TARGETARCH's, hence the translation.
ARG TTYD_VERSION=1.7.7
RUN set -eu; \
    case "${TARGETARCH}" in \
        amd64) ttyd_arch=x86_64 ;; \
        arm64) ttyd_arch=aarch64 ;; \
        *) echo "vhs-base: no known ttyd release asset for TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /usr/local/bin/ttyd \
        "https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}/ttyd.${ttyd_arch}" \
    && chmod 0755 /usr/local/bin/ttyd

# The client for the platform-owned buildkitd — see ci-base/Dockerfile for the whole argument.
# tapes/prepare.sh is what calls it, to build a repository's CLI natively before its tapes run.
COPY --from=buildkit /usr/bin/buildctl /usr/local/bin/buildctl

# The headless JRE, for FakePlatformMain. /opt/java/openjdk is Temurin's own layout; copied whole
# rather than apt-installed, since bookworm has no JRE 25 package.
ENV JAVA_HOME=/opt/java/openjdk
ENV PATH="$JAVA_HOME/bin:$PATH"
COPY --from=jre /opt/java/openjdk /opt/java/openjdk

# Every tool a tape depends on, checked once so a broken one fails the build and never the
# automation or a QA step months later.
RUN vhs --version \
    && ttyd --version \
    && ffmpeg -version \
    && buildctl --version \
    && java -version

# The step-image contract (see node-browser-base and maven-base): /workspace sticky and
# world-writable, because qits-ci-daemon clones into it and steps run cap-dropped; and git's
# safe.directory exemption, because the clone's owner is not always the user running git.
RUN mkdir -p /workspace \
    && chmod 1777 /workspace \
    && git config --system --add safe.directory '*'
