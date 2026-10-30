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
| `qits/build-images/node-browser-base` | Node plus the pinned screenshot renderer (Playwright Chromium and fonts); the `app` QA step and the workspace image both build on it |
| `qits/build-images/vhs-base` | Pinned vhs/ttyd/Chromium/font stack that plays `tapes/*.tape`; the `cli-tapes` QA step and qits-maintenance's `cli-tapes` automation both build on it |
| `qits/build-images/ci-slot` | The one CI image: every step of a run executes in it (epic qits-1481). The union of the step images above, Debian bookworm, no docker; `ci-slot/check-tools.sh` lists the commands it must carry and the release fails without them. `ENTRYPOINT` runs `/usr/local/bin/ci-slot-entrypoint`, which execs the bootstrap script qits-ci-service hands the container in `QITS_CI_BOOTSTRAP` — the lease container starts with no command override, so this is the only thing that ever runs; it exits 64 if the variable is unset. No `CMD`. |

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

Only ci-slot reads the build context: the `ci-slot` stage copies in `ci-slot/ci-slot-entrypoint`
(its `ENTRYPOINT`) and the `check` target on top of it copies `ci-slot/check-tools.sh`.
`--target ci-slot` builds the image itself and `--target check` runs the tool check. Keeping the
repository root as the context leaves room for shared scripts without changing the release
pipeline.

Running `qits/build-images/ci-slot` by hand needs `QITS_CI_BOOTSTRAP` set, since the image has no
`CMD` and its `ENTRYPOINT` execs that variable's contents or refuses with exit 64:

```sh
docker run -e QITS_CI_BOOTSTRAP='echo hi' qits/build-images/ci-slot:local
```

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
