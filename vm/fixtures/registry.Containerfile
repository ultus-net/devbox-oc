# A Fedora registry for the rollback rehearsal. The official registry:2 image is
# Alpine, so the package the Fedora family ships is installed instead.
FROM registry.fedoraproject.org/fedora@sha256:3632de47c2cef45d6a6ea6a420280ff9ce452e225a1b291299c105b9d9bae471

RUN set -eux; \
    dnf install -y --setopt=install_weak_deps=False docker-distribution; \
    dnf clean all

EXPOSE 5000
ENTRYPOINT ["/usr/bin/registry", "serve", "/etc/docker-distribution/registry/config.yml"]
