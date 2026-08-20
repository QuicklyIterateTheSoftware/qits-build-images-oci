# qits-oci

Build definitions for the base OCI images used by qits CI pipelines. The images live together
because they are one platform surface and deliberately share one release version.

## Images

| Image | Purpose |
|---|---|
| `qits/build-images/ci-base` | Minimal Git/Bash/Docker publishing step |
| `qits/build-images/maven-base` | Maven and JDK 25 build step |
| `qits/build-images/userflows-base` | Maven plus the browser toolchain used by qits-userflows |
| `qits/build-images/node-base` | Node and Corepack build/publish step |
| `qits/build-images/node-docker-base` | Node build step that can also drive the host Docker daemon |

Every release publishes every image with the release CalVer and with `latest`. The immutable
CalVer is the release coordinate; `latest` is the channel consumed by CI configurations. Registry
layers are content-addressed, so unchanged content is shared even when a new tag is added.

The repository has no `pom.xml`, `package.json`, or version file. That is intentional. A qits
release creates the version and annotated Git tag, then supplies the same version in the
`SCMRelease` event that runs `.config/qits/ci-event-release.yml`.

## Building locally

Build one image from the repository root:

```sh
docker build -f ci-base/Dockerfile -t qits/build-images/ci-base:local .
```

The Dockerfiles currently need no files from the build context. Keeping the repository root as the
context leaves room for shared scripts without changing the release pipeline.

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

The release step itself runs in `qits/build-images/ci-base:latest`, so a completely fresh platform
must seed that image before this repository can take ownership of publishing it. The platform's
local bootstrap already does so. Once seeded, releases are self-hosting.

**That circularity is irreducible and is not what the registry resolution fixed.** A pipeline that
publishes the step images runs on one of them, so the very first copy has to come from outside CI.
What changed is the blast radius of losing them *afterwards*: a host that has been pruned re-pulls
what it lost from the registry instead of needing the bootstrap again. Seeding is a cold-start
concern; it is no longer a recovery procedure.

To rebuild the whole set by hand on a host that has lost them and cannot reach the registry either:

```sh
for i in ci-base maven-base userflows-base node-base node-docker-base; do
  docker build -t "qits/build-images/$i:latest" -f "$i/Dockerfile" .
done
```
