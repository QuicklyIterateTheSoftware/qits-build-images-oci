# qits-build-images-oci

Build definitions for the base OCI images used by qits CI pipelines. The images live together
because they are one platform surface and deliberately share one release version.

## Images

| Image | Purpose |
|---|---|
| `qits/build-images/ci-base` | Minimal Git/Bash/Docker publishing step |
| `qits/build-images/maven-base` | Maven and JDK 25 build step |
| `qits/build-images/userflows-base` | Maven plus the browser toolchain used by qits-userflows-javalib |
| `qits/build-images/node-base` | Node and Corepack build/publish step |
| `qits/build-images/node-docker-base` | Node build step that can also drive the host Docker daemon |
| `qits/build-images/node-browser-base` | Node plus the pinned screenshot renderer (Playwright Chromium and fonts); the `app` QA step and the workspace image both build on it. Carries the [trust hook](#platform-trust-anchors) the workspace, desk and agent images start through |
| `qits/build-images/vhs-base` | Pinned vhs/ttyd/Chromium/font stack that plays `tapes/*.tape`; the `cli-tapes` QA step and qits-maintenance's `cli-tapes` automation both build on it |
| `qits/build-images/ci-slot` | The one CI image: every step of a run executes in it (epic qits-1481). The union of the step images above, Debian bookworm, no docker; `ci-slot/check-tools.sh` lists the commands it must carry and the release fails without them. `ENTRYPOINT` runs `/usr/local/bin/qits-trust-init` (see [Platform trust anchors](#platform-trust-anchors)), which execs `/usr/local/bin/ci-slot-entrypoint`, which execs the bootstrap script qits-ci-service hands the container in `QITS_CI_BOOTSTRAP` — the lease container starts with no command override, so this is the only thing that ever runs; it exits 64 if the variable is unset. No `CMD`. |

Every release publishes every image with the release CalVer and with `latest`. The immutable
CalVer is the release coordinate; `latest` is the channel consumed by CI configurations. Registry
layers are content-addressed, so unchanged content is shared even when a new tag is added.

The repository has no `pom.xml`, `package.json`, or version file. That is intentional. A qits
release creates the version and annotated Git tag, then supplies the same version in the
`SCMRelease` event that runs the `release:` slot of `.config/qits/release.yml`.

## Building locally

Build one image from the repository root:

```sh
docker build -f ci-base/Dockerfile -t qits/build-images/ci-base:local .
```

The repository root is every build's context, which is how two images share one copy of a script.
ci-slot copies in `ci-slot/ci-slot-entrypoint` (its `ENTRYPOINT`), and both ci-slot and
node-browser-base copy `trust/qits-trust-layout` and `trust/qits-trust-init`. Both also have a
`check` target that the release builds before it pushes anything. ci-slot's runs
`ci-slot/check-tools.sh` and both run `trust/test-trust.sh --installed`. In ci-slot,
`--target ci-slot` builds the image itself. node-browser-base needs no target, because its last
stage is the image and BuildKit skips `check` unless asked:

```sh
docker build --target check -f ci-slot/Dockerfile .
docker build --target check -f node-browser-base/Dockerfile .
```

Running `qits/build-images/ci-slot` by hand needs `QITS_CI_BOOTSTRAP` set, since the image has no
`CMD` and its `ENTRYPOINT` execs that variable's contents or refuses with exit 64:

```sh
docker run -e QITS_CI_BOOTSTRAP='echo hi' qits/build-images/ci-slot:local
```

## Platform trust anchors

The platform's own CA reaches a container as PEM in `QITS_TRUST_ANCHORS`. Workspace, desk, agent
and ci-slot containers run as a non-root uid, so they cannot run `update-ca-certificates` at start.
Instead, node-browser-base and ci-slot ship a two-part hook (epic qits-2524). The source is `trust/`,
and the spec is the epic's dossier page "Image trust hook".

**At build, `qits-trust-layout` runs as root.** It is idempotent. It creates `/etc/ssl/qits/` with
mode 0777 and its files with mode 0666, and points every store at a file there:

| File | Content | Linked from |
|---|---|---|
| `public-bundle.pem` | the image's own system bundle, copied at build and never rewritten | |
| `ca-bundle.pem` | the public bundle plus the anchors | `/etc/ssl/certs/ca-certificates.crt` |
| `anchors.pem` | the anchors alone, or empty | |
| `public-cacerts` | the JDK's original cacerts, copied at build and never rewritten (ci-slot) | |
| `java-cacerts` | the public cacerts plus each anchor, as alias `qits-platform-ca-<12 hex of sha256(DER)>` | `$JAVA_HOME/lib/security/cacerts` (ci-slot) |

A tool that reads a bundle path of its own is covered by static ENV in both images.
`NODE_EXTRA_CA_CERTS`, `REQUESTS_CA_BUNDLE`, `PIP_CERT`, `SSL_CERT_FILE`, `CURL_CA_BUNDLE` and
`GIT_SSL_CAINFO` all equal `/etc/ssl/qits/ca-bundle.pem`. Because the ENV is in the image, a
`docker exec` shell sees the same trust as the entrypoint's children.

Run the layout again after anything that reinstalls `ca-certificates` or a JDK. qits-workspace-oci
does this once it has installed its JDK. `update-ca-certificates` turns the linked bundle back into a
regular file, and the next layout run re-copies it.

**At start, `qits-trust-init <command> [args...]` runs as any uid.** It writes the CERTIFICATE blocks
of `QITS_TRUST_ANCHORS` into the three files. Each file is written under a temporary name and then
renamed, so a reader never sees half a store. Then it `exec`s the command. When the variable is
unset or empty, it resets the files to the public copies. It never stops a start: any failure prints
one line, `qits-trust-init: <what>; continuing with public trust`, to stderr. It then leaves public
trust in place and still execs the command. One anchor takes about half a second, most of it
keytool's JVM start; the budget is 2 s.

ci-slot starts through it: `ENTRYPOINT ["/usr/local/bin/qits-trust-init",
"/usr/local/bin/ci-slot-entrypoint"]`. node-browser-base has no entrypoint of its own. The images
built on it put `qits-trust-init` in front of theirs.

**The test is `trust/test-trust.sh`.** It needs no root and no docker. It makes a throwaway P-384 CA
and a leaf for `trust.test`, and serves the leaf with `openssl s_server`. It then checks that curl,
git, node `fetch`, python3 `urllib`, keytool and a JVM all refuse the CA before the init and trust it
after. It also checks that a start without anchors is public trust, byte for byte, and that a
malformed value still execs with its one stderr line. Run it from the repository root before pushing
a change to `trust/`:

```sh
TRUST_TEST_STRICT=1 sh trust/test-trust.sh            # simulates /etc/ssl/qits in a temp dir
sh trust/test-trust.sh --installed                    # inside an image; the check targets run this
```

The simulation sets `QITS_TRUST_DIR` and `QITS_TRUST_SYSTEM_BUNDLE`. These two variables exist only
for the test, and they override `/etc/ssl/qits` and `/etc/ssl/certs/ca-certificates.crt`.

## Init hooks

Just before `qits-trust-init` execs the command it was given, it sources every `/etc/qits/init.d/*.sh`
it finds, in name order, in its own (main) shell — sourced, not run, so a hook's `export`s reach the
command about to be exec'd and everything that command launches (epic qits-2525, qits-2656, dossier
page "Reaching the proxy", section "The init hook"). The motivating consumer is a hook
`/etc/qits/init.d/50-egress.sh` that qits-workspace-oci's own work places there, to start
`qits egress forward` and export the proxy ENV an agent container's tools need to reach outside
resources through qits-egress — a separate repository's concern; this repository only has to carry
the hook mechanism itself.

Each hook is sourced inside a guard: it runs in a subshell of its own, so a hook that turns on
`set -e` and then fails, or that calls `exit` explicitly, ends only that subshell, never
`qits-trust-init` — calling `exit` from a hook is a bug (it only cuts that hook short and loses any
export still to come), but it does not take the container down with it. The subshell's exports are
carried back into the main shell by dumping `export -p` to a temp file just before the subshell ends,
then sourcing that dump — plain `export` statements, nothing that can fail. A hook whose last command
fails, directly or through its own `set -e`, is reported on stderr as one line,
`qits-trust-init: hook <file> failed`, with every export it made in that run discarded, and the start
goes on to the next hook and then the exec. With no `/etc/qits/init.d`, behaviour is exactly as if
this mechanism did not exist.

### The workload certificate hook (`40-workload-certificate.sh`, qits-2762)

`node-browser-base` (and so every image on it: qits/workspace-base, the agent, desk and workspace
containers) carries `/etc/qits/init.d/40-workload-certificate.sh` (epic qits-2626). When the
container holds `QITS_TOKEN` and a `qits` CLI that has `certificate keep`, it starts `qits
certificate keep --dir $QITS_WORKLOAD_CERT_DIR` in the background and exports
`QITS_WORKLOAD_CERT_DIR` (default `/run/qits/workload`): `key.pem` (0600), `cert.pem` and
`chain.pem` appear within seconds, name the token's principal (mostly `project:<id>`), and are
renewed at 2/3 of their day for as long as the container runs. The key is made in the container and
never leaves it.

- **Otherwise it does nothing**: no token (a daemon image on its service client), no qits, or a
  qits too old to know the command — the last says so in one stderr line, `qits-workload-certificate:
  …; continuing without a workload certificate`. It never stops a start.
- **`/run/qits` is 1777**, made by `qits-trust-layout`, so `keep`, as whatever uid the container runs,
  creates `/run/qits/workload` itself, owned by that uid and 0700. A directory made at build time would
  be root's, and the CLI could not make it private.
- `keep` logs to the container's stderr itself: one line per certificate, one per failure streak.
- `trust/test-trust.sh` proves it with a fake `qits` on PATH: started with the token and exporting the
  directory, nothing without a token or a CLI, one line and the start going on with an old CLI, and
  `/run/qits` 1777 (`QITS_RUN_DIR` overrides it in the simulation).

`trust/test-trust.sh` proves all of it — a hook's export reaching `qits-trust-init env`, a failing
hook not stopping the exec (and not blocking a later hook), name order, and no hook directory
changing nothing — through `QITS_INIT_HOOK_DIR`, which overrides `/etc/qits/init.d` for the test only,
the same way `QITS_TRUST_DIR` overrides `/etc/ssl/qits`.

## How a recipe consumes these

Every recipe on the platform opens with a bare name — `image: qits/build-images/ci-base:latest` —
and that is deliberate: a recipe states no deployment fact, exactly as a publish script composes
`$QITS_REGISTRY` rather than naming a host. **qits-ci resolves it**, prefixing the platform registry
when the first path segment is the platform's own image repository (`CiStepImage`, and only then —
a reference that already names a registry, and a single-segment official image like `docker:cli`,
are both left alone).

That resolution is what makes these ordinary published images rather than bootstrap residue. A bare
name is resolved by docker against Docker Hub, so before it existed the reference worked only
because the image happened to be in the host's local store, put there by the bootstrap — and a
`docker system prune` therefore deleted the entire CI plane of the platform, with `pull access
denied for qits/build-images/ci-base` on every build in every repository and a bootstrap rerun as
the only recovery. It is now a pull.

## Bootstrap

**This repository's own pipelines run on `qits/build-images/ci-base:latest` with `build: true`**,
building through the platform buildkitd with `buildctl` and pushing straight to the registry
(qits-1540). Until then they ran on upstream `docker:28-dind` with `docker: true`, so that nothing
here needed one of the images it publishes: on 2026-08-20 a `docker system prune` deleted every
image from the host's local store and the pipeline that would have rebuilt them needed one of them
to run. The images are pulled from the registry now rather than found in a local store, and once CI
runs in a slot a `docker: true` step is a configuration error, so the self-hosting is accepted: the
cold-machine recovery is the loop below, by hand.

To rebuild the whole set by hand — a cold machine with no registry and no CI:

```sh
for i in ci-base maven-base userflows-base node-base node-docker-base node-browser-base vhs-base ci-slot; do
  target=; [ "$i" = ci-slot ] && target='--target ci-slot'
  docker build $target -t "qits/build-images/$i:latest" -f "$i/Dockerfile" .
done
```

The 2026.821 release republished all five images after the 2026-08-20
prune left the registry without them; the loop above was the bridge.
