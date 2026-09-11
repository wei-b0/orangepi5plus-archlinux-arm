FROM debian:bookworm-slim@sha256:88200866dfff7ea7f5cbcb6ec7c8a701889efe6fe859fe64d6990e4b07ea4171

ARG DEBIAN_SNAPSHOT=20260805T000000Z

RUN rm -f /etc/apt/sources.list.d/debian.sources \
    && printf '%s\n' \
    "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT}/ bookworm main" \
    "deb [check-valid-until=no] http://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT}/ bookworm-security main" \
    > /etc/apt/sources.list \
    && apt-get -o Acquire::Check-Valid-Until=false update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
       bc bison build-essential ca-certificates cpio curl device-tree-compiler e2fsprogs \
       faketime fdisk file flex gdisk git gnupg gpgv libarchive-tools libelf-dev \
       libgnutls28-dev libssl-dev make openssl parted patch python3 python3-dev \
       python3-pyelftools python3-setuptools rsync swig udev util-linux xxd xz-utils zstd \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8 LC_ALL=C.UTF-8 TZ=UTC

WORKDIR /repo
