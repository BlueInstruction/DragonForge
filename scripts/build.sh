#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

VERSION="${1:-}"
ARCH="${2:-x86_64}"
OUTPUT_DIR="${3:-$PROJECT_ROOT/output}"

REPO_URL="https://github.com/HansKristian-Work/vkd3d-proton.git"
SRC_DIR="$PROJECT_ROOT/src"

log() {
    echo "[$(date '+%H:%M:%S')] $*"
}

error() {
    echo "[ERROR] $*" >&2
    exit 1
}

fetch_version() {
    if [[ -z "$VERSION" ]]; then
        log "fetching latest version"
        VERSION=$(curl -sL https://api.github.com/repos/HansKristian-Work/vkd3d-proton/releases/latest | grep -oP '"tag_name":\s*"\K[^"]+') || true
        [[ -z "$VERSION" ]] && error "failed to fetch latest version"
    fi
    [[ "$VERSION" =~ ^v ]] || VERSION="v$VERSION"
    log "version: $VERSION"
}

clone_source() {
    if [[ -d "$SRC_DIR" ]]; then
        log "removing existing source directory"
        rm -rf "$SRC_DIR"
    fi

    log "cloning vkd3d-proton $VERSION"
    git clone --branch "$VERSION" --depth 1 "$REPO_URL" "$SRC_DIR"

    cd "$SRC_DIR"
    log "initializing submodules"
    git submodule update --init --recursive --depth 1 --jobs 4

    COMMIT=$(git rev-parse --short=8 HEAD)
    log "commit: $COMMIT"
    export COMMIT
}

apply_patches() {
    log "applying performance patches"
    if ! python3 "$PROJECT_ROOT/patches/performance.py" "$SRC_DIR" --arch "$ARCH" --report; then
        error "patch application failed"
    fi
    log "patches applied successfully"
}

build_x86_64() {
    log "building x86_64"

    export CFLAGS="-O3 -march=x86-64-v3 -mtune=generic -msse4.2 -mavx -mavx2 -mfma -ffast-math -fno-math-errno -fomit-frame-pointer -flto=auto -fno-semantic-interposition -DNDEBUG"
    export CXXFLAGS="$CFLAGS"
    export LDFLAGS="-Wl,-O2 -Wl,--as-needed -Wl,--gc-sections -flto=auto -s"

    cd "$SRC_DIR"
    chmod +x ./package-release.sh
    ./package-release.sh "$VERSION" "$OUTPUT_DIR" --no-package
}

build_arm64ec() {
    log "building arm64ec"

    cat > "$PROJECT_ROOT/arm64ec-cross.txt" << 'EOF'
[binaries]
c = 'aarch64-w64-mingw32-gcc'
cpp = 'aarch64-w64-mingw32-g++'
ar = 'aarch64-w64-mingw32-ar'
strip = 'llvm-strip'
windres = 'aarch64-w64-mingw32-windres'
widl = 'aarch64-w64-mingw32-widl'

[built-in options]
c_args = ['-O3', '-DNDEBUG', '-ffast-math', '-fno-strict-aliasing', '-mno-outline-atomics', '-flto=auto', '-fno-semantic-interposition']
cpp_args = ['-O3', '-DNDEBUG', '-ffast-math', '-fno-strict-aliasing', '-mno-outline-atomics', '-flto=auto', '-fno-semantic-interposition']
c_link_args = ['-static', '-s', '-flto=auto']
cpp_link_args = ['-static', '-s', '-flto=auto']

[host_machine]
system = 'windows'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF

    cat > "$PROJECT_ROOT/i686-cross.txt" << 'EOF'
[binaries]
c = 'i686-w64-mingw32-gcc'
cpp = 'i686-w64-mingw32-g++'
ar = 'i686-w64-mingw32-ar'
strip = 'llvm-strip'
windres = 'i686-w64-mingw32-windres'
widl = 'i686-w64-mingw32-widl'

[built-in options]
c_args = ['-O3', '-DNDEBUG', '-ffast-math', '-fno-strict-aliasing', '-msse', '-msse2', '-flto=auto', '-fno-semantic-interposition']
cpp_args = ['-O3', '-DNDEBUG', '-ffast-math', '-fno-strict-aliasing', '-msse', '-msse2', '-flto=auto', '-fno-semantic-interposition']
c_link_args = ['-static', '-s', '-flto=auto']
cpp_link_args = ['-static', '-s', '-flto=auto']

[host_machine]
system = 'windows'
cpu_family = 'x86'
cpu = 'i686'
endian = 'little'
EOF

    cd "$SRC_DIR"

    log "configuring arm64ec build"
    meson setup build-arm64ec \
        --cross-file "$PROJECT_ROOT/arm64ec-cross.txt" \
        --buildtype release \
        -Denable_tests=false \
        -Denable_extras=false

    log "compiling arm64ec"
    ninja -C build-arm64ec -j"$(nproc)"

    log "configuring i686 build"
    meson setup build-i686 \
        --cross-file "$PROJECT_ROOT/i686-cross.txt" \
        --buildtype release \
        -Denable_tests=false \
        -Denable_extras=false

    log "compiling i686"
    ninja -C build-i686 -j"$(nproc)"
}

verify_build() {
    log "verifying build"
    local errors=0

    if [[ "$ARCH" == "x86_64" ]]; then
        BUILD_OUTPUT=$(find "$OUTPUT_DIR" -maxdepth 1 -type d -name "vkd3d-proton-*" | head -1)
        [[ -z "$BUILD_OUTPUT" ]] && error "build output not found"

        for arch in x64 x86; do
            for dll in d3d12.dll d3d12core.dll; do
                dll_path="$BUILD_OUTPUT/$arch/$dll"
                if [[ ! -f "$dll_path" ]]; then
                    log "missing: $dll_path"
                    ((errors++))
                else
                    log "$dll_path: $(stat -c%s "$dll_path") bytes"
                fi
            done
        done
    else
        for arch in arm64ec i686; do
            for dll in d3d12.dll d3d12core.dll; do
                dll_path=$(find "$SRC_DIR/build-$arch" -name "$dll" -type f 2>/dev/null | head -1)
                if [[ -z "$dll_path" ]]; then
                    log "missing: $dll ($arch)"
                    ((errors++))
                else
                    log "$dll ($arch): $(stat -c%s "$dll_path") bytes"
                fi
            done
        done
    fi

    [[ $errors -gt 0 ]] && error "build verification failed with $errors error(s)"
}

main() {
    log "vkd3d-proton build script"
    fetch_version
    clone_source
    apply_patches

    if [[ "$ARCH" == "x86_64" ]]; then
        build_x86_64
    else
        build_arm64ec
    fi

    verify_build
    log "build complete"

    {
        echo "VERSION=${VERSION#v}"
        echo "COMMIT=$COMMIT"
    } >> "${GITHUB_ENV:-/dev/null}"
}

main "$@"
