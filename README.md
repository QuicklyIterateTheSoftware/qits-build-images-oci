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

## No bootstrap

**This repository's own pipelines run on `docker:28-dind`, an upstream image pulled through the
platform's OCI mirror**, so nothing here needs one of the images it publishes. That is what makes
these ordinary build artifacts: the platform can rebuild its own CI plane from a clone and a mirror,
with no seeded state anywhere.

It used to run on `qits/build-images/ci-base:latest`, and the circularity that created was not
theoretical. On 2026-08-20 a `docker system prune` reclaiming a full disk deleted all five images;
every build in every repository then failed with `pull access denied for qits/build-images/ci-base`,
and the pipeline that would have rebuilt them needed one of them to run. There was no run left
anywhere on the platform that could fix it.

`docker:28-dind` is the one upstream image carrying **docker and git** together, which is the
daemon's image contract — git plus a downloader, and busybox supplies `wget`. It has no `bash`, and
qits-ci-daemon no longer requires one: it probes for bash, uses it when present so no existing
pipeline changes behaviour, and falls back to `sh` when absent. Every script in this repository is
POSIX, including the deliberate `sed`-instead-of-`jq` version parse in the release pipeline.

To rebuild the whole set by hand — a cold machine with no registry and no CI:

```sh
for i in ci-base maven-base userflows-base node-base node-docker-base; do
  docker build -t "qits/build-images/$i:latest" -f "$i/Dockerfile" .
done
```

The 2026.821 release republished all five images after the 2026-08-20
prune left the registry without them; the loop above was the bridge.
