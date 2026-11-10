# syntax=docker/dockerfile:1

# Fedora toolbox base.
#
# Why not ghcr.io/anomalyco/opencode: that image is musl/Alpine on every
# platform (verified in its layer history). A Fedora host needs the glibc
# build, so OpenCode is fetched from the npm registry as a platform tarball and
# pinned by sha512 integrity, not by tag. No npm client is needed for that.
#
# The toolbox image is built for interactive dev use: it includes dnf,
# bash, git and the usual tooling, and it is what `toolbox create` gives
# you locally. That parity is the point: the same image runs on your
# workstation.
#
# Pin by DIGEST. The `46` tag currently resolves to content labelled
# `org.opencontainers.image.version: rawhide`, so the tag is not a
# reliable version signal.
ARG BASE=registry.fedoraproject.org/fedora-toolbox@sha256:2c8a6048963d9006e0d5d01399cb0817f073ccf2e181b97db300db29d1c57a3f

FROM ${BASE}

ARG DEV_UID=1000
ARG DEV_GID=1000

# OpenCode version and the sha512 of its linux-x64 platform tarball.
# Both come from the npm registry metadata for @opencode/cli-linux-x64.
# Bump these together; the build fails if the digests disagree.
ARG OC_VERSION=2.1.4
ARG OC_SHA512=o8EJ0ZsT4dzDKN+0mpG2EKbNGzJyp+F1++Av28UReRVfiEv+N34eZEnN/unkiMoerKHad6W6Ii7k4ukTnPNmNQ==

USER root

RUN set -eux; \
    dnf install -y --setopt=install_weak_deps=False \
      bash \
      ca-certificates \
      containers-common \
      curl \
      fd-find \
      findutils \
      git \
      jq \
      less \
      openssh-clients \
      procps-ng \
      ripgrep \
      tar \
      tzdata \
      which; \
    dnf clean all

# Install OpenCode from the platform artifact, verifying integrity before use.
# curl and tar are already present; nodejs and npm are not needed for the binary.
RUN set -eux; \
    url="https://registry.npmjs.org/@opencode/cli-linux-x64/-/cli-linux-x64-${OC_VERSION}.tgz"; \
    curl -fsSL --retry 3 --output /tmp/oc.tgz "$url"; \
    printf '%s' "${OC_SHA512}" | base64 -d | od -An -tx1 | tr -d ' \n' > /tmp/oc.sha512.hex; \
    actual="$(sha512sum /tmp/oc.tgz | cut -d' ' -f1)"; \
    expected="$(cat /tmp/oc.sha512.hex)"; \
    if [ "$actual" != "$expected" ]; then \
      echo "integrity mismatch for $url" >&2; \
      echo "expected $expected" >&2; \
      echo "actual   $actual" >&2; \
      exit 1; \
    fi; \
    tar -xzf /tmp/oc.tgz -C /tmp package/bin/opencode; \
    install -m 0755 /tmp/package/bin/opencode /usr/local/bin/opencode; \
    rm /tmp/oc.tgz /tmp/oc.sha512.hex; \
    opencode --version

RUN set -eux; \
    install -d -m 0755 /etc/containers/registries.conf.d && \
    printf '%s\n' '[registries.search]' 'registries = ["docker.io"]' \
      > /etc/containers/registries.conf.d/010-devbox.conf

COPY toolchains.txt /tmp/toolchains.txt
RUN set -eux; \
    pkgs="$(grep -vE '^[[:space:]]*(#|$)' /tmp/toolchains.txt | tr '\n' ' ')"; \
    if [ -n "${pkgs}" ]; then dnf install -y --setopt=install_weak_deps=False ${pkgs}; fi; \
    dnf clean all; \
    rm /tmp/toolchains.txt

# The quadlet's HealthCmd runs this once :prod carries it; that switch is a
# tracked follow-up (#23), not part of this build.
COPY --chmod=0755 healthcheck.sh /usr/local/bin/devbox-health

# Unprivileged user with a fixed uid so host bind mounts line up.
RUN set -eux; \
    groupadd -g ${DEV_GID} dev; \
    useradd -m -u ${DEV_UID} -g dev -s /bin/bash dev

USER dev
WORKDIR /home/dev
EXPOSE 4096

# No ENTRYPOINT in the toolbox image, and it defaults to bash. Set it here so
# `docker compose exec opencode ...` still lands in a shell when you override.
ENTRYPOINT ["opencode"]
CMD ["serve", "--hostname", "0.0.0.0", "--port", "4096"]
