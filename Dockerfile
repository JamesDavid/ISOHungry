# ---- stage 1: build libdvdcss (CSS decryption for commercial DVDs) ----
# Not in Debian main. Built from VideoLAN source so the runtime image carries
# no extra apt repos and no toolchain.
FROM debian:bookworm-slim AS dvdcss

ARG LIBDVDCSS_VERSION=1.4.3

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential ca-certificates wget; \
    wget -qO /tmp/libdvdcss.tar.bz2 \
        "https://download.videolan.org/pub/libdvdcss/${LIBDVDCSS_VERSION}/libdvdcss-${LIBDVDCSS_VERSION}.tar.bz2"; \
    mkdir -p /tmp/src; \
    tar -xjf /tmp/libdvdcss.tar.bz2 -C /tmp/src --strip-components=1; \
    cd /tmp/src; \
    ./configure --prefix=/usr --libdir=/usr/lib/dvdcss; \
    make -j"$(nproc)"; \
    make install DESTDIR=/staging

# gum: the TUI styling the script's name always implied. Single static binary,
# pulled from the release tarball to avoid trusting another apt repo.
ARG GUM_VERSION=0.14.5
ARG TARGETARCH
RUN set -eux; \
    case "${TARGETARCH:-amd64}" in \
      amd64) GUM_ARCH=x86_64 ;; \
      arm64) GUM_ARCH=arm64  ;; \
      arm)   GUM_ARCH=armv7  ;; \
      *)     GUM_ARCH=x86_64 ;; \
    esac; \
    wget -qO /tmp/gum.tar.gz \
        "https://github.com/charmbracelet/gum/releases/download/v${GUM_VERSION}/gum_${GUM_VERSION}_Linux_${GUM_ARCH}.tar.gz"; \
    mkdir -p /tmp/gum; \
    tar -xzf /tmp/gum.tar.gz -C /tmp/gum --strip-components=1; \
    install -D -m 0755 /tmp/gum/gum /staging/usr/bin/gum; \
    /staging/usr/bin/gum --version

# ---- stage 2: runtime ----
FROM debian:bookworm-slim

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        dvdbackup \
        genisoimage \
        libdvdread8 \
        eject \
        util-linux \
        procps \
        ncurses-bin \
        tzdata \
        usbip; \
    rm -rf /var/lib/apt/lists/*

# libdvdread dlopen()s libdvdcss.so.2 at runtime; ldconfig makes it findable.
COPY --from=dvdcss /staging/usr/lib/dvdcss/ /usr/lib/dvdcss/
COPY --from=dvdcss /staging/usr/bin/gum /usr/bin/gum
RUN echo /usr/lib/dvdcss > /etc/ld.so.conf.d/dvdcss.conf && ldconfig

COPY 04_gum_auto_dvd_backup.sh /usr/local/bin/auto-dvd-backup
RUN chmod +x /usr/local/bin/auto-dvd-backup

# C.UTF-8 makes bash count characters rather than bytes, so the status line
# no longer slices emoji in half mid-scroll.
ENV BASE_OUTPUT_DIR=/output \
    POLL_INTERVAL=5 \
    MAX_PARALLEL=2 \
    TERM=xterm-256color \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    DVDCSS_METHOD=key

VOLUME ["/output"]

ENTRYPOINT ["/usr/local/bin/auto-dvd-backup"]
