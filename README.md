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

## Bootstrap

The release step itself runs in `qits/build-images/ci-base:latest`, so a completely fresh platform
must seed that image before this repository can take ownership of publishing it. The platform's
local bootstrap already does so. Once seeded, releases are self-hosting.
