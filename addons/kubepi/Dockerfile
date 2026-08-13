# syntax=docker/dockerfile:1.7
FROM scratch
COPY --chmod=0444 jasper-k8s-kubepi-offline.tar.zst /jasper-k8s-kubepi-offline.tar.zst
COPY --chmod=0444 jasper-k8s-kubepi-offline.tar.zst.sha256 /jasper-k8s-kubepi-offline.tar.zst.sha256
COPY --chmod=0444 provenance.json /provenance.json
COPY --chmod=0444 source-images.lock /source-images.lock
COPY --chmod=0444 SHA256SUMS /SHA256SUMS
