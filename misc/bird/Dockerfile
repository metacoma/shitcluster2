# BIRD 2.15 — ready image plus iproute2/sysctl tooling
# Base: pierky/bird:2.15 (Debian 12, BIRD 2.15) — version matches prod 2.15.1
FROM pierky/bird:2.15

# Pin Debian suite to bookworm (stable moved to trixie)
RUN sed -i 's/Suites: stable stable-updates/Suites: bookworm bookworm-updates/' /etc/apt/sources.list.d/debian.sources \
    && sed -i 's/Suites: stable-security/Suites: bookworm-security/' /etc/apt/sources.list.d/debian.sources

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        iproute2 \
        iputils-ping \
        procps \
        ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# BIRD daemon in foreground; config mounted at /etc/bird/bird.conf
ENTRYPOINT ["bird", "-f", "-c", "/etc/bird/bird.conf"]
