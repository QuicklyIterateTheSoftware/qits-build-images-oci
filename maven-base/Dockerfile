FROM maven:3.9-eclipse-temurin-25-alpine

# util-linux is here for `setsid --ctty`, and only busybox would make that a surprise. The base is
# Alpine, so `setsid` is a busybox applet that takes `-c` and rejects `--ctty` outright — and the
# daemon repositories' PTY suites spawn their children through the util-linux spelling. Without
# this every one of those tests fails in CI with "setsid: unrecognized option: ctty" while passing
# on any developer's glibc machine, which is the worst shape a test failure can have.
RUN apk add --no-cache bash curl git jq util-linux

# A build user, so a step that must not be root can be STARTED as one.
#
# Zonky's embedded postgres is what needs it: initdb refuses to run as uid 0, and it calls
# getpwuid — so a bare `--user 1001` is not enough, the uid has to be backed by a passwd entry.
# `adduser -D` (alpine) writes one.
#
# It cannot be done inside a step's script, which is what the pipelines used to try. Step containers
# are started `--cap-drop=ALL`: without CAP_SETUID and CAP_SETGID `su` cannot switch user at all, and
# without CAP_CHOWN even root cannot chown. Measured 2026-08-12, on qits-containers' first real
# post-receive run — `chown: /workspace: Operation not permitted`. The only moment a user can be
# chosen is the `docker run`, which is what `user:` in a step declaration now renders.
#
# /workspace is created here because the ci-daemon clones into it, and a non-root container user
# cannot make a directory at the root of the filesystem. It carries /tmp's mode (1777), not an
# owner: root steps lost DAC_OVERRIDE with the rest of their capabilities, so a build-owned 755
# directory refused THEM instead — measured 2026-08-12, every release pipeline red with
# "/workspace/.git: Permission denied". World-writable and sticky serves both kinds of step; each
# container is fresh, so nothing shares the directory with anyone.
RUN adduser -D -u 1001 build \
    && mkdir -p /workspace \
    && chmod 1777 /workspace
