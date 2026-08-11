FROM node:24-alpine

# docker-cli-buildx makes every `docker build` on this image run under buildkit — the CLI uses the
# plugin the moment it exists. The legacy builder's shared cache intermediates are collected by
# containerd's own GC mid-build when concurrent builds of one Dockerfile race (measured on
# qits-gateway's 2026-08-11 release); buildkit's cache has no such shared-export path. Every
# pipeline that passes `--network qits-net` must move to the host doctrine BEFORE this ships:
# buildkit refuses custom networks.
RUN apk add --no-cache bash curl docker-cli docker-cli-buildx git \
    && corepack enable
