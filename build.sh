#!/usr/bin/env bash
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
source "$repo_root/config/versions.env"
container_image=orangepi5plus-arch-builder:2026-08-05
volume_name=orangepi5plus-arch-build
command_name=${1:-build}

build_container() {
    docker build --platform linux/arm64 --build-arg DEBIAN_SNAPSHOT=20260805T000000Z -t "$container_image" "$repo_root"
}

run_builder() {
    local volume=$1
    local script=$2
    shift 2
    docker run --rm --privileged --platform linux/arm64 \
        -e JOBS="${JOBS:-}" \
        -v "$repo_root:/repo" -v "$volume:/work" \
        -w /repo "$container_image" "$script" "$@"
}

case "$command_name" in
    fetch)
        build_container
        run_builder "$volume_name" /repo/scripts/fetch.sh
        ;;
    refresh-packages)
        build_container
        run_builder "$volume_name" /repo/scripts/refresh-packages.sh
        ;;
    build)
        build_container
        run_builder "$volume_name" /repo/scripts/build-in-container.sh
        ;;
    rebuild-kernel-nvme)
        build_container
        docker volume rm -f orangepi5plus-nvme-kernel >/dev/null 2>&1 || true
        docker run --rm --privileged --platform linux/arm64 -e JOBS="${JOBS:-}" \
            -e WORK_ROOT=/work/nvme-kernel -v "$repo_root:/repo" -v orangepi5plus-nvme-kernel:/work \
            -w /repo "$container_image" bash /repo/scripts/rebuild-kernel-image-in-container.sh
        docker volume rm -f orangepi5plus-nvme-kernel >/dev/null 2>&1 || true
        ;;
    inspect)
        build_container
        run_builder "$volume_name" /repo/scripts/inspect.sh /repo/dist/"$IMAGE_NAME"
        ;;
    verify-reproducible)
        build_container
        docker volume rm -f orangepi5plus-repro-a orangepi5plus-repro-b >/dev/null 2>&1 || true
        docker run --rm --platform linux/arm64 -e JOBS="${JOBS:-}" -e WORK_ROOT=/work/run -e OUTPUT_NAME=repro-a.img -e RUN_LABEL=repro-a \
            -v "$repo_root:/repo" -v orangepi5plus-repro-a:/work -w /repo "$container_image" /repo/scripts/build-in-container.sh
        cp "$repo_root/dist/build-manifest.txt" "$repo_root/dist/repro-a-manifest.txt"
        cp "$repo_root/dist/inspection.txt" "$repo_root/dist/repro-a-inspection.txt"
        sha_a=$(sha256sum "$repo_root/dist/repro-a.img" | cut -d' ' -f1)
        zsha_a=$(sha256sum "$repo_root/dist/repro-a.img.zst" | cut -d' ' -f1)
        docker volume rm -f orangepi5plus-repro-a >/dev/null
        docker run --rm --platform linux/arm64 -e JOBS="${JOBS:-}" -e WORK_ROOT=/work/run -e OUTPUT_NAME=repro-b.img -e RUN_LABEL=repro-b \
            -v "$repo_root:/repo" -v orangepi5plus-repro-b:/work -w /repo "$container_image" /repo/scripts/build-in-container.sh
        cp "$repo_root/dist/build-manifest.txt" "$repo_root/dist/repro-b-manifest.txt"
        cp "$repo_root/dist/inspection.txt" "$repo_root/dist/repro-b-inspection.txt"
        sha_b=$(sha256sum "$repo_root/dist/repro-b.img" | cut -d' ' -f1)
        zsha_b=$(sha256sum "$repo_root/dist/repro-b.img.zst" | cut -d' ' -f1)
        test "$sha_a" = "$sha_b"
        test "$zsha_a" = "$zsha_b"
        mv "$repo_root/dist/repro-a.img" "$repo_root/dist/$IMAGE_NAME.tmp"
        mv "$repo_root/dist/$IMAGE_NAME.tmp" "$repo_root/dist/$IMAGE_NAME"
        mv "$repo_root/dist/repro-a.img.zst" "$repo_root/dist/$IMAGE_NAME.zst.tmp"
        mv "$repo_root/dist/$IMAGE_NAME.zst.tmp" "$repo_root/dist/$IMAGE_NAME.zst"
        chmod 0644 "$repo_root/dist/$IMAGE_NAME"
        chmod 0644 "$repo_root/dist/$IMAGE_NAME.zst"
        rm -f "$repo_root/dist/repro-a.img.sha256" "$repo_root/dist/repro-a.img.zst.sha256"
        rm -f "$repo_root/dist/repro-b.img" "$repo_root/dist/repro-b.img.sha256" "$repo_root/dist/repro-b.img.zst" "$repo_root/dist/repro-b.img.zst.sha256"
        (cd "$repo_root/dist" && sha256sum "$IMAGE_NAME" > "$IMAGE_NAME.sha256")
        (cd "$repo_root/dist" && sha256sum "$IMAGE_NAME.zst" > "$IMAGE_NAME.zst.sha256")
        sed -i.bak "s/repro-b\\.img/$IMAGE_NAME/g" "$repo_root/dist/build-manifest.txt"
        rm -f "$repo_root/dist/build-manifest.txt.bak"
        run_builder orangepi5plus-repro-b /repo/scripts/inspect.sh "/repo/dist/$IMAGE_NAME" | tee "$repo_root/dist/inspection.txt"
        printf 'raw_sha256=%s\ncompressed_sha256=%s\n' "$sha_a" "$zsha_a" | tee "$repo_root/dist/reproducibility.txt"
        docker volume rm -f orangepi5plus-repro-a orangepi5plus-repro-b >/dev/null
        ;;
    clean)
        docker volume rm -f "$volume_name" >/dev/null 2>&1 || true
        find "$repo_root/dist" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} + 2>/dev/null || true
        ;;
    *)
        printf 'Usage: %s {fetch|refresh-packages|build|rebuild-kernel-nvme|inspect|verify-reproducible|clean}\n' "$0" >&2
        exit 2
        ;;
esac
