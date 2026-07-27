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
        usbip \
        python3 \
        abcde \
        cdparanoia \
        cd-discid \
        libcdio-utils \
        lame \
        flac \
        eyed3 \
        id3v2 \
        vorbis-tools \
        curl; \
    rm -rf /var/lib/apt/lists/*

# libdvdread dlopen()s libdvdcss.so.2 at runtime; ldconfig makes it findable.
COPY --from=dvdcss /staging/usr/lib/dvdcss/ /usr/lib/dvdcss/
COPY --from=dvdcss /staging/usr/bin/gum /usr/bin/gum
RUN echo /usr/lib/dvdcss > /etc/ld.so.conf.d/dvdcss.conf && ldconfig

COPY isohungry.sh /usr/local/bin/isohungry
COPY entrypoint.sh /usr/local/bin/entrypoint
COPY web/ /opt/isohungry/
COPY scripts/retag-music.sh /opt/isohungry/retag-music.sh
RUN chmod +x /usr/local/bin/isohungry /usr/local/bin/entrypoint \
             /opt/isohungry/retag-music.sh

# C.UTF-8 makes bash count characters rather than bytes, so the status line
# no longer slices emoji in half mid-scroll.
ENV BASE_OUTPUT_DIR=/output \
    POLL_INTERVAL=5 \
    MAX_PARALLEL=2 \
    TERM=xterm-256color \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    DVDCSS_METHOD=key

ENV WEB_UI=1 \
    WEB_PORT=8080

VOLUME ["/output"]
EXPOSE 8080

ENTRYPOINT ["/usr/local/bin/entrypoint"]
