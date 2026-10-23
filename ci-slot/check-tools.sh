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
wc
'

# Not called by name in a step script, but part of the image contract the dossier lists, and what
# the named commands need underneath: java for ./mvnw, npx for Playwright, corepack behind pnpm,
# bash for the daemon's shell probe, jq and setsid (util-linux) for test suites, skopeo for the OCI
# userflow stories, flock for the daemon's warm-base mirror lock.
contract_commands='
bash
corepack
flock
java
jq
npx
setsid
skopeo
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

# The ENTRYPOINT (qits-1540): a lease container starts with no command override, so this is what
# runs the bootstrap script qits-ci-service hands in QITS_CI_BOOTSTRAP. Not on PATH by name-lookup
# convention; check the fixed path directly.
if ! [ -x /usr/local/bin/ci-slot-entrypoint ]; then
  echo "check-tools: /usr/local/bin/ci-slot-entrypoint is missing or not executable" >&2
  status=1
fi

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
