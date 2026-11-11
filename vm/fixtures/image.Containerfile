# One of two disposable tags for the rollback rehearsal. It is built FROM the
# image the host runs, so the workload stays the shipped one and only the label
# differs between the older and newer tags.
ARG BASE
FROM ${BASE}
ARG VARIANT
LABEL org.ultus.devbox.vm-fixture=${VARIANT}
# A real layer, not just metadata: two tags must have distinct manifests, and a
# metadata-only change can be served from the build cache under one digest.
RUN printf '%s\n' "$VARIANT" > /tmp/devbox-vm-fixture
