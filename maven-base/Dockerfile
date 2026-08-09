FROM maven:3.9-eclipse-temurin-25-alpine

# util-linux is here for `setsid --ctty`, and only busybox would make that a surprise. The base is
# Alpine, so `setsid` is a busybox applet that takes `-c` and rejects `--ctty` outright — and the
# daemon repositories' PTY suites spawn their children through the util-linux spelling. Without
# this every one of those tests fails in CI with "setsid: unrecognized option: ctty" while passing
# on any developer's glibc machine, which is the worst shape a test failure can have.
RUN apk add --no-cache bash curl git jq util-linux
