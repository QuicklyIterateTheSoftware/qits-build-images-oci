FROM mcr.microsoft.com/playwright/java:v1.61.0-noble

RUN apt-get update \
    && apt-get install -y --no-install-recommends curl git jq maven \
    && rm -rf /var/lib/apt/lists/*
