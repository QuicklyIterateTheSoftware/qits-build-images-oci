#!/bin/sh
# Fails, naming every one, when a command a CI step calls is missing from this image — and when
# `docker` is present, because ci-slot has no docker by design.
#
# Run by the `check` stage of ci-slot/Dockerfile, which the release builds before it pushes.
#
# WHERE THE LIST CAME FROM. Derived on 2026-10-23 (qits-1540) by extracting every `script:`/`run:`
# block of
#
#   components/qits-ci/qits-ci-service/ci/src/main/resources/release-archetypes/*.yml   (8 recipes)
#   components/*/*/.config/qits/release.yml                                          (55 files)
#
# in the qits-qits wrapper, dropping comment lines, and collecting the word in command position
# (line start, after `|`, `&&`, `||`, `;`, `$(`, `then`, `do`, `if`, `!`, after `env VAR=…`).
# Then kept only real executables. Left out on purpose:
#
#   - shell builtins and keywords: cd echo exit export printf read return set true ulimit umask,
#     `[`/test, case/for/if/while and friends;
#   - functions the scripts define (pnpm_install, write_npmrc, install_coverage_provider, …);
#   - ./mvnw and repository-local scripts (`sh scripts/…`), which the repository brings;
#   - qits and qits-publish: the composed release prelude downloads them and puts them on PATH;
#   - wget: only ever the fallback arm of `curl … || wget …`, and curl is here;
#   - docker: gone by design, asserted ABSENT below.
#
# Re-derive when a recipe or a release.yml starts calling something new; a step that needs a tool
# this list does not name is a step that will fail in the slot.
#
# RE-CHECKED on 2026-10-26 (qits-1649) against two sources the first derivation missed, because the
# step scripts are not the only callers: test suites and build tools exec commands themselves
# (`ProcessBuilder`, `child_process`), and the Alpine step images answered those through busybox
# without anybody naming them — `unzip` (qits-1540) and `kill` (qits-1649) were both that. (a) The
# union of every command on PATH in the replaced step images (maven-base, node-base,
# node-browser-base, userflows-base): 289 of them were absent from ci-slot. (b) What test code
# execs, across every submodule: `ProcessBuilder`/`child_process` literals and the
# `onPath`/`available`/`command -v` skip-guards. Only psmisc's process tools were added; the rest
# of the union is left out on purpose because nothing calls it — kernel, boot, systemd, dbus, apk,
# network-admin and console applets, and the Alpine maven image's binutils. Re-derive from BOTH
# sources when a step, a test or a build tool starts calling something new.
set -u

# Called by the step scripts.
step_commands='
buildctl
cat
chmod
cp
curl
cut
env
find
git
grep
head
ls
mkdir
mktemp
mvn
node
npm
pnpm
rm
sed
sh
sha256sum
sleep
tar
tr
vhs
wc
'

# Not called by name in a step script, but part of the image contract the dossier lists, and what
# the named commands need underneath: java for ./mvnw, npx for Playwright, corepack behind pnpm,
# bash for the daemon's shell probe, jq and setsid (util-linux) for test suites, skopeo for the OCI
# userflow stories, flock for the daemon's warm-base mirror lock, unzip for ./mvnw's own hidden
# dependency — the wrapper script only falls back to `.tar.gz` when `command -v unzip` fails, and
# then still validates it against the `.zip`'s distributionSha256Sum, so a slot without `unzip`
# fails every `./mvnw` with "Failed to validate Maven distribution SHA-256" (qits-1540). kill,
# pgrep, pkill and ps come from procps, which Java tests and step scripts exec directly — e.g.
# qits-projects-service's `HangupImmunityTest` sends itself `kill -HUP` (qits-1540). fuser, killall
# and pstree come from psmisc, the rest of busybox's process applets (qits-1649). ttyd and ffmpeg
# are vhs's own underneath (epic qits-881): vhs shells out to ttyd for the pty-over-websocket bridge
# it drives a browser against and to ffmpeg to encode the captured frames into a GIF; the cli-tapes
# recipe never names either. chromium is checked separately below, since a dangling symlink would
# still pass a bare `command -v`.
contract_commands='
bash
corepack
ffmpeg
flock
fuser
java
jq
kill
killall
npx
pgrep
pkill
ps
pstree
setsid
skopeo
ttyd
unzip
'

missing=''
for command in $step_commands $contract_commands; do
  if ! command -v "$command" >/dev/null 2>&1; then
    missing="$missing $command"
  fi
done

status=0
if [ -n "$missing" ]; then
  echo "check-tools: missing from this image:$missing" >&2
  status=1
fi

# git http-backend is a git subcommand, not a PATH entry (maven-base's git-daemon comment).
if ! [ -x "$(git --exec-path)/git-http-backend" ]; then
  echo "check-tools: git http-backend is missing from this image" >&2
  status=1
fi

# chromium (epic qits-881): vhs/go-rod's launcher.LookPath() finds its browser by this name on
# PATH — the Dockerfile symlinks it to Playwright's own Chromium rather than installing or
# downloading a second one. A bare `command -v` (what the loop above runs for every other command)
# would still pass with a dangling symlink, so resolve it and actually run it.
if ! chromium_path="$(command -v chromium)"; then
  echo "check-tools: chromium is missing from this image" >&2
  status=1
elif ! "$chromium_path" --version >/dev/null 2>&1; then
  echo "check-tools: chromium at $chromium_path does not run --version" >&2
  status=1
fi

# The ENTRYPOINT (qits-1540): a lease container starts with no command override, so this is what
# runs the bootstrap script qits-ci-service hands in QITS_CI_BOOTSTRAP. Not on PATH by name-lookup
# convention; check the fixed path directly.
if ! [ -x /usr/local/bin/ci-slot-entrypoint ]; then
  echo "check-tools: /usr/local/bin/ci-slot-entrypoint is missing or not executable" >&2
  status=1
fi

# The runner mounts fresh named volumes on these paths, and a new volume takes the ownership of the
# image's directory: each must exist and be the build user's, or uid 1001 cannot write to it.
for dir in /work /work/home /cache/git /caches/m2 /caches/pnpm; do
  if ! [ -d "$dir" ] || ! [ -w "$dir" ]; then
    echo "check-tools: $dir is missing or not writable by $(id -un)" >&2
    status=1
  fi
done

for forbidden in docker docker-buildx; do
  if command -v "$forbidden" >/dev/null 2>&1; then
    echo "check-tools: $forbidden is present at $(command -v "$forbidden"); ci-slot has no docker by design" >&2
    status=1
  fi
done

if [ "$status" = 0 ]; then
  echo "check-tools: all $(printf '%s\n' $step_commands $contract_commands | grep -c .) commands present, no docker"
fi
exit "$status"
