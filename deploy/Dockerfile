# Overlay our console build on top of the pinned Higress all-in-one image that already runs on the server.
# The base image is tagged locally on the server (see setup-server.sh), so upstream "latest" drift never
# changes the gateway/controller versions without an explicit re-pin.
ARG BASE_IMAGE=higress-aio-base:pinned
FROM ${BASE_IMAGE}

COPY higress-console.jar /app/higress-console.jar
