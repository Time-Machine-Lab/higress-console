# Overlay our console build on top of a pinned Higress all-in-one image.
# The base is pinned by digest so upstream "latest" drift never changes the gateway/controller
# versions without an explicit re-pin. To move to a newer Higress, pull the new all-in-one,
# take its digest and update BASE_IMAGE here.
ARG BASE_IMAGE=higress-registry.cn-hangzhou.cr.aliyuncs.com/higress/all-in-one@sha256:55f5fa3ec77d5c00c5622c05019e6deb030b195bb0efa7212eff3555c071bed0
FROM ${BASE_IMAGE}

COPY higress-console.jar /app/higress-console.jar
