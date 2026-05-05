FROM debian:bookworm-slim

ARG APTLY_UID=1000
ARG APTLY_GID=1000
ARG GIT_SHA=unknown

LABEL org.opencontainers.image.source="https://github.com/pders01/aptly-mirror" \
      org.opencontainers.image.description="Aptly-based Debian mirror with non-root runtime" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.revision="${GIT_SHA}"

# Pull aptly from upstream repo — Debian's package lags releases.
# https://www.aptly.info/download/
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates curl gnupg && \
    install -d -m 0755 /etc/apt/keyrings && \
    curl -fsSL https://www.aptly.info/pubkey.txt \
        | gpg --dearmor -o /etc/apt/keyrings/aptly.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/aptly.gpg] http://repo.aptly.info/ squeeze main" \
        > /etc/apt/sources.list.d/aptly.list && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        aptly \
        bzip2 \
        xz-utils && \
    apt-get purge -y curl && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

RUN groupadd --system --gid "${APTLY_GID}" aptly && \
    useradd  --system --uid "${APTLY_UID}" --gid aptly \
             --home-dir /var/lib/aptly --shell /usr/sbin/nologin aptly && \
    install -d -o aptly -g aptly -m 0755 /var/lib/aptly /home/aptly /home/aptly/.gnupg && \
    chmod 700 /home/aptly/.gnupg

USER aptly
WORKDIR /var/lib/aptly
ENV HOME=/home/aptly \
    GNUPGHOME=/home/aptly/.gnupg

ENTRYPOINT ["aptly"]
CMD ["version"]
