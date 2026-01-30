#!/usr/bin/env bash
set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
log_step() { echo -e "${BLUE}[STEP]${NC} $*"; }

: "${UNI_KIND:?UNI_KIND is required}"
: "${REL_TAG_STABLE:?REL_TAG_STABLE is required}"
: "${PATCH_DIR:?PATCH_DIR is required}"
: "${OUT_DIR:?OUT_DIR is required}"

ref="${1:?ref is required}"
ver_name="${2:?ver_name is required}"
filename="${3:?filename is required}"

log_info "Building ${ver_name} from ref: ${ref}"
log_info "Output file: ${filename}"

detect_arm64ec_toolchain() {
    log_step "Detecting ARM64EC toolchain..."
    
    if command -v arm64ec-w64-mingw32-gcc &> /dev/null; then
        log_info "Found: arm64ec-w64-mingw32-gcc"
        echo "arm64ec-mingw"
        return 0
    fi
        
    if command -v aarch64-w64-mingw32-gcc &> /dev/null; then
        log_info "Found: aarch64-w64-mingw32-gcc (LLVM-MinGW)"
        echo "aarch64-mingw"
        return 0
    fi
    
    if command -v clang &> /dev/null && command -v lld &> /dev/null; then
        log_info "Found: clang with lld (will use ARM64EC target)"
        echo "clang-arm64ec"
        return 0
    fi
    
    log_error "No suitable ARM64EC toolchain found!"
    log_error "Please install one of:"
    log_error "  1. arm64ec-w64-mingw32-gcc"
    log_error "  2. aarch64-w64-mingw32-gcc (LLVM-MinGW)"
    log_error "  3. clang + lld (LLVM)"
    return 1
}

TOOLCHAIN_TYPE=$(detect_arm64ec_toolchain)

log_step "Checking required tools..."
for cmd in meson ninja patch tar; do
    if ! command -v "$cmd" &> /dev/null; then
        log_error "Required command not found: $cmd"
        exit 1
    fi
done

log_info "Meson version: $(meson --version)"
log_info "Ninja version: $(ninja --version)"


log_step "Creating toolchain configuration files..."

log_info "Creating build-win32.txt..."
cat > build-win32.txt << 'TOOLCHAIN_EOF'
[binaries]
c = 'i686-w64-mingw32-gcc'
cpp = 'i686-w64-mingw32-g++'
ar = 'i686-w64-mingw32-ar'
strip = 'i686-w64-mingw32-strip'
windres = 'i686-w64-mingw32-windres'
exe_wrapper = 'wine'

[properties]
c_args = []
cpp_args = []
c_link_args = []
cpp_link_args = []

[host_machine]
system = 'windows'
cpu_family = 'x86'
cpu = 'i686'
endian = 'little'
TOOLCHAIN_EOF

log_info "Creating toolchains/arm64ec.meson.ini for ${TOOLCHAIN_TYPE}..."
mkdir -p toolchains

case "$TOOLCHAIN_TYPE" in
    "arm64ec-mingw")
        cat > toolchains/arm64ec.meson.ini << 'TOOLCHAIN_EOF'
[binaries]
c       = 'arm64ec-w64-mingw32-gcc'
cpp     = 'arm64ec-w64-mingw32-g++'
ar      = 'arm64ec-w64-mingw32-ar'
windres = 'arm64ec-w64-mingw32-windres'
widl    = 'arm64ec-w64-mingw32-widl'
strip   = 'llvm-strip'

[host_machine]
system     = 'windows'
cpu_family = 'aarch64'
cpu        = 'aarch64'
endian     = 'little'
TOOLCHAIN_EOF
        ;;
    
    "aarch64-mingw")
        cat > toolchains/arm64ec.meson.ini << 'TOOLCHAIN_EOF'
[binaries]
c       = 'aarch64-w64-mingw32-gcc'
cpp     = 'aarch64-w64-mingw32-g++'
ar      = 'aarch64-w64-mingw32-ar'
windres = 'aarch64-w64-mingw32-windres'
widl    = 'aarch64-w64-mingw32-widl'
strip   = 'aarch64-w64-mingw32-strip'

[properties]
c_args = ['-marm64ec']
cpp_args = ['-marm64ec']

[host_machine]
system     = 'windows'
cpu_family = 'aarch64'
cpu        = 'aarch64'
endian     = 'little'
TOOLCHAIN_EOF
        ;;
    
    "clang-arm64ec")
        cat > toolchains/arm64ec.meson.ini << 'TOOLCHAIN_EOF'
[binaries]
c       = 'clang'
cpp     = 'clang++'
ar      = 'llvm-ar'
strip   = 'llvm-strip'

[properties]
c_args = [
    '-target', 'arm64ec-pc-windows-msvc',
    '-Wno-unused-command-line-argument',
    '-D_WIN32_WINNT=0x0A00'
]
cpp_args = [
    '-target', 'arm64ec-pc-windows-msvc',
    '-Wno-unused-command-line-argument',
    '-D_WIN32_WINNT=0x0A00'
]
c_link_args = [
    '-target', 'arm64ec-pc-windows-msvc',
    '-fuse-ld=lld',
    '-Wl,/machine:arm64ec'
]
cpp_link_args = [
    '-target', 'arm64ec-pc-windows-msvc',
    '-fuse-ld=lld',
    '-Wl,/machine:arm64ec'
]

[host_machine]
system     = 'windows'
cpu_family = 'aarch64'
cpu        = 'aarch64'
endian     = 'little'
TOOLCHAIN_EOF
        ;;
esac

log_info "✓ Toolchain files created for: ${TOOLCHAIN_TYPE}"


if ! command -v i686-w64-mingw32-gcc &> /dev/null; then
    log_error "i686-w64-mingw32-gcc not found"
    log_error "Install: sudo apt install gcc-mingw-w64-i686 g++-mingw-w64-i686"
    exit 1
fi

log_info "✓ All required tools are available"


log_step "Setting up build environment..."

PKG_ROOT="../pkg_temp/${UNI_KIND}-${ref}"
rm -rf "${PKG_ROOT}"
mkdir -p "${PKG_ROOT}"

rm -rf build_x86 build_ec

if [[ -d "$PATCH_DIR" ]] && [[ -n "$(ls -A "$PATCH_DIR"/*.patch 2>/dev/null)" ]]; then
    log_step "Applying patches from $PATCH_DIR..."
    patch_count=0
    for patch_file in "$PATCH_DIR"/*.patch; do
        [[ -f "$patch_file" ]] || continue
        log_info "  → Applying $(basename "$patch_file")..."
        
        if ! patch -p1 --dry-run < "$patch_file" &>/dev/null; then
            log_warn "Patch $(basename "$patch_file") already applied or incompatible, skipping..."
            continue
        fi
        
        patch -p1 < "$patch_file"
        ((patch_count++))
    done
    log_info "✓ Applied $patch_count patch(es) successfully"
else
    log_warn "No patches found in $PATCH_DIR"
fi

log_step "Compiling x86 (32-bit)..."

if ! meson setup build_x86 \
    --cross-file build-win32.txt \
    --buildtype release \
    --prefix "$PWD/${PKG_ROOT}/x32"; then
    log_error "Meson setup failed for x86"
    [[ -f build_x86/meson-logs/meson-log.txt ]] && cat build_x86/meson-logs/meson-log.txt
    exit 1
fi

if ! ninja -C build_x86 install; then
    log_error "Ninja build failed for x86"
    exit 1
fi

log_info "✓ x86 build completed"

log_step "Compiling ARM64EC (using ${TOOLCHAIN_TYPE})..."

ARGS_FLAGS=""

if [[ -n "${MOCK_DIR:-}" ]]; then
    log_info "Using ARM64EC shim from MOCK_DIR=$MOCK_DIR"
    ARGS_FLAGS="-I${MOCK_DIR} -include sarek_all_in_one.h"
elif [[ -n "${ARM64EC_CPP_ARGS:-}" ]]; then
    log_info "Using custom ARM64EC cpp_args: ${ARM64EC_CPP_ARGS}"
    ARGS_FLAGS="${ARM64EC_CPP_ARGS}"
fi

_orig_cflags="${CFLAGS:-}"
_orig_cxxflags="${CXXFLAGS:-}"

if ! CFLAGS="${_orig_cflags}" \
     CXXFLAGS="${_orig_cxxflags:+${_orig_cxxflags} }${ARGS_FLAGS}" \
     meson setup build_ec \
       --cross-file toolchains/arm64ec.meson.ini \
       --buildtype release \
       --prefix "$PWD/${PKG_ROOT}/arm64ec" \
       ${ARGS_FLAGS:+-Dcpp_args="${ARGS_FLAGS}"}; then
    log_error "Meson setup failed for ARM64EC"
    [[ -f build_ec/meson-logs/meson-log.txt ]] && cat build_ec/meson-logs/meson-log.txt
    exit 1
fi

if ! ninja -C build_ec install; then
    log_error "Ninja build failed for ARM64EC"
    exit 1
fi

log_info "✓ ARM64EC build completed"

log_step "Preparing WCP package..."

WCP_DIR="../${REL_TAG_STABLE}_WCP"
rm -rf "$WCP_DIR"
mkdir -p "$WCP_DIR"/{bin,lib,share}

SRC_EC="${PKG_ROOT}/arm64ec"
SRC_32="${PKG_ROOT}/x32"

if [[ ! -d "$SRC_EC/bin" ]]; then
    log_error "ARM64EC bin directory not found: $SRC_EC/bin"
    exit 1
fi

cp -r "$SRC_EC/bin" "$WCP_DIR/"
cp -r "$SRC_EC/lib" "$WCP_DIR/"
cp -r "$SRC_EC/share" "$WCP_DIR/"

HAS_PREFIX_PACK=false
if [[ -f "$SRC_EC/prefixPack.txz" ]]; then
    cp "$SRC_EC/prefixPack.txz" "$WCP_DIR/"
    log_info "✓ Copied prefixPack.txz"
    HAS_PREFIX_PACK=true
fi

log_step "Creating profile.json..."

if [[ "$HAS_PREFIX_PACK" == true ]]; then
    cat > "$WCP_DIR/profile.json" <<EOF
{
  "type": "Wine",
  "versionName": "${ver_name}",
  "versionCode": 0,
  "description": "Proton ${REL_TAG_STABLE} ARM64EC (${TOOLCHAIN_TYPE})",
  "files": [],
  "wine": {
    "binPath": "bin",
    "libPath": "lib",
    "prefixPack": "prefixPack.txz"
  }
}
EOF
else
    cat > "$WCP_DIR/profile.json" <<EOF
{
  "type": "Wine",
  "versionName": "${ver_name}",
  "versionCode": 0,
  "description": "Proton ${REL_TAG_STABLE} ARM64EC (${TOOLCHAIN_TYPE})",
  "files": [],
  "wine": {
    "binPath": "bin",
    "libPath": "lib"
  }
}
EOF
fi

log_step "Creating compressed archive..."

mkdir -p "$OUT_DIR"

if ! tar -cJf "$OUT_DIR/$filename" -C "$WCP_DIR" .; then
    log_error "Failed to create archive"
    exit 1
fi

file_size=$(du -h "$OUT_DIR/$filename" | cut -f1)

if command -v sha256sum &> /dev/null; then
    checksum=$(sha256sum "$OUT_DIR/$filename" | cut -d' ' -f1)
    echo "$checksum" > "$OUT_DIR/${filename}.sha256"
    log_info "SHA256: $checksum"
fi

echo ""
echo "═══════════════════════════"
echo -e "${GREEN}BUILD SUCCESSFUL!${NC}"
echo "═══════════════════════════"
echo "Version:      ${ver_name}"
echo "Ref:          ${ref}"
echo "Toolchain:    ${TOOLCHAIN_TYPE}"
echo "Output:       $OUT_DIR/$filename"
echo "Size:         ${file_size}"
[[ -f "$OUT_DIR/${filename}.sha256" ]] && echo "Checksum:     $OUT_DIR/${filename}.sha256"
echo "══════════════════════════"

if [[ "${CLEANUP_BUILD:-false}" == "true" ]]; then
    log_info "Cleaning up..."
    rm -rf build_x86 build_ec "$PKG_ROOT" "$WCP_DIR"
fi

log_info "All done!"
