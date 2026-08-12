# syntax=docker/dockerfile:1.7
FROM scratch
COPY --chmod=0444 kubespray-offline-base.tar.zst /kubespray-offline-base.tar.zst
COPY --chmod=0444 kubespray-offline-base.tar.zst.sha256 /kubespray-offline-base.tar.zst.sha256
COPY --chmod=0444 provenance.json /provenance.json
COPY --chmod=0444 source-images.lock /source-images.lock
COPY --chmod=0444 SHA256SUMS /SHA256SUMS
