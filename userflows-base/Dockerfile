FROM mcr.microsoft.com/playwright/java:v1.61.0-noble

# `skopeo` is here for the `qits` (OCI) story category in qits-artifacts' userflows: those stories
# drive a real `skopeo copy` push and pull against the registry process the suite launches. It is the
# only proof in the suite that a REAL OCI client can push to and pull from that registry — every
# other check is written from this platform's own reading of the spec, and a reading cannot disagree
# with itself. The stories pass `--insecure-policy` deliberately: ubuntu's skopeo ships
# `/etc/containers/policy.json` by way of containers-common, so without the flag the stories would
# pass on a policy file this image happens to install, and the image must not be what silently makes
# them pass.
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl git jq maven skopeo \
    && rm -rf /var/lib/apt/lists/*

# The step-image contract maven-base wrote down, restated here because this image runs `mvn verify`
# for the userflow pipelines and their suites spawn zonky's embedded postgres:
#
#   - a PASSWD-BACKED non-root user, so a step can be STARTED as one (`user: pwuser`): initdb
#     refuses uid 0 and calls getpwuid, and a step script cannot switch users itself — containers
#     run --cap-drop=ALL, so the `docker run` user is the only choice there is. The Playwright base
#     ships `pwuser`; the guard below only creates it if a future base stops doing so.
#   - /workspace at 1777, because the ci-daemon clones into it and a non-root container user cannot
#     make a directory at the root of the filesystem (measured 2026-08-28: the first userflows run
#     as pwuser died with "could not create work tree dir '/workspace': Permission denied").
#     Sticky-world-writable rather than owned, for maven-base's reason: cap-dropped root steps lost
#     DAC_OVERRIDE, so an owned 755 would refuse THEM instead. Each container is fresh; nothing
#     shares the directory with anyone.
#   - the safe.directory exemption, git's CVE-2022-24765 half of 1777: root-owned /workspace,
#     non-root git.
RUN getent passwd pwuser >/dev/null || useradd -m pwuser; \
    mkdir -p /workspace \
    && chmod 1777 /workspace \
    && git config --system --add safe.directory /workspace
