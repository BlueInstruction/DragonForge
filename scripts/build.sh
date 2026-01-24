#!/bin/bash -e

set -o pipefail

# CONFIG
BUILD_DIR="$(pwd)/build_workspace"
PATCHES_DIR="$(pwd)/patches"
NDK_VERSION="${NDK_VERSION:-android-ndk-r30}"
API_LEVEL="${API_LEVEL:-35}"

# Mesa Sources
MESA_FREEDESKTOP="https://gitlab.freedesktop.org/mesa/mesa.git"
MESA_FREEDESKTOP_MIRROR="https://github.com/mesa3d/mesa.git"
MESA_8GEN_SOURCE="https://github.com/whitebelyash/mesa-tu8.git"
MESA_8GEN_BRANCH="8gen"

# Runtime Config from Environment
MESA_SOURCE_TYPE="${MESA_SOURCE_TYPE:-official_release}"
OFFICIAL_VERSION="${OFFICIAL_VERSION:-25.3.4}"
STAGING_BRANCH="${STAGING_BRANCH:-staging/25.3}"
CUSTOM_COMMIT="${CUSTOM_COMMIT:-}"
MESA_REPO_SOURCE="${MESA_REPO_SOURCE:-freedesktop}"
BUILD_VARIANT="${BUILD_VARIANT:-a7xx}"
NAMING_FORMAT="${NAMING_FORMAT:-emulator}"
COMMIT_HASH_SHORT=""
MESA_VERSION=""
MAX_RETRIES=3
RETRY_DELAY=15
BUILD_DATE=$(date '+%Y-%m-%d %H:%M:%S')

# LOGGING
log()     { echo "[Build] $1"; }
success() { echo "[OK] $1"; }
warn()    { echo "[WARN] $1"; }
error()   { echo "[ERROR] $1"; exit 1; }
info()    { echo "[INFO] $1"; }
header()  { echo -e "\n=== $1 ==="; }

# UTILITIES
retry_command() {
    local cmd="$1"
    local description="$2"
    local attempt=1

    while [ $attempt -le $MAX_RETRIES ]; do
        log "Attempt $attempt/$MAX_RETRIES: $description"
        if eval "$cmd"; then
            return 0
        fi
        warn "Failed, retrying in ${RETRY_DELAY}s..."
        sleep $RETRY_DELAY
        ((attempt++))
    done

    return 1
}

check_dependencies() {
    log "Checking dependencies..."
    local deps=(git curl unzip patchelf zip meson ninja ccache)
    local missing=()

    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing+=("$dep")
        fi
    done

    if [ ${#missing[@]} -gt 0 ]; then
        error "Missing dependencies: ${missing[*]}"
    fi
    success "All dependencies found"
}

# NDK SETUP
setup_ndk() {
    header "NDK Setup"

    if [ -n "${ANDROID_NDK_LATEST_HOME}" ] && [ -d "${ANDROID_NDK_LATEST_HOME}" ]; then
        export ANDROID_NDK_HOME="${ANDROID_NDK_LATEST_HOME}"
        info "Using system NDK: $ANDROID_NDK_HOME"
        return
    fi

    if [ -d "$BUILD_DIR/$NDK_VERSION" ]; then
        export ANDROID_NDK_HOME="$BUILD_DIR/$NDK_VERSION"
        info "Using cached NDK: $ANDROID_NDK_HOME"
        return
    fi

    log "Downloading NDK $NDK_VERSION..."
    local ndk_url="https://dl.google.com/android/repository/${NDK_VERSION}-linux.zip"

    if ! retry_command "curl -sL '$ndk_url' -o core.zip" "Downloading NDK"; then
        error "Failed to download NDK"
    fi

    unzip -q core.zip && rm -f core.zip
    export ANDROID_NDK_HOME="$BUILD_DIR/$NDK_VERSION"
    success "NDK installed: $ANDROID_NDK_HOME"
}

# MESA CLONE
clone_mesa() {
    header "Mesa Source Selection"

    [ -d "$BUILD_DIR/mesa" ] && rm -rf "$BUILD_DIR/mesa"

    case "$MESA_SOURCE_TYPE" in
        "official_release")
            clone_official_release
            ;;
        "staging_branch")
            clone_staging_branch
            ;;
        "custom_commit")
            clone_custom_commit
            ;;
        *)
            warn "Unknown source type: $MESA_SOURCE_TYPE, defaulting to official_release"
            clone_official_release
            ;;
    esac

    setup_mesa_repo
}

clone_official_release() {
    log "Cloning official release: $OFFICIAL_VERSION"
    
    if [ "$MESA_REPO_SOURCE" = "8gen" ]; then
        warn "8gen source doesn't have official releases, cloning from GitHub..."
        retry_command "git clone --depth=200 --branch '$MESA_8GEN_BRANCH' '$MESA_8GEN_SOURCE' '$BUILD_DIR/mesa'" "Cloning 8gen source"
        return
    fi
    
    if ! retry_command "git clone --depth 500 '$MESA_FREEDESKTOP' '$BUILD_DIR/mesa'" "Cloning from GitLab"; then
        warn "GitLab unavailable, trying GitHub mirror..."
        retry_command "git clone --depth 500 '$MESA_FREEDESKTOP_MIRROR' '$BUILD_DIR/mesa'" "Cloning from GitHub"
    fi
    
    cd "$BUILD_DIR/mesa"
    
    if [ "$OFFICIAL_VERSION" = "custom" ]; then
        warn "Using latest available version"
        return
    fi
    
    if git tag -l | grep -q "mesa-$OFFICIAL_VERSION"; then
        log "Checking out version: mesa-$OFFICIAL_VERSION"
        git checkout "mesa-$OFFICIAL_VERSION"
    elif git tag -l | grep -q "$OFFICIAL_VERSION"; then
        log "Checking out version: $OFFICIAL_VERSION"
        git checkout "$OFFICIAL_VERSION"
    else
        warn "Version $OFFICIAL_VERSION not found, using latest stable"
        LATEST_TAG=$(git tag -l "mesa-*" | grep -E 'mesa-[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -1)
        if [ -n "$LATEST_TAG" ]; then
            log "Using latest stable: $LATEST_TAG"
            git checkout "$LATEST_TAG"
        fi
    fi
}

clone_staging_branch() {
    log "Cloning staging branch: $STAGING_BRANCH"
    
    if [ "$MESA_REPO_SOURCE" = "8gen" ]; then
        warn "8gen source doesn't have staging branches, using 8gen branch"
        retry_command "git clone --depth=200 --branch '$MESA_8GEN_BRANCH' '$MESA_8GEN_SOURCE' '$BUILD_DIR/mesa'" "Cloning 8gen source"
        return
    fi
    
    if ! retry_command "git clone --depth 500 --branch '$STAGING_BRANCH' '$MESA_FREEDESKTOP' '$BUILD_DIR/mesa'" "Cloning staging branch"; then
        warn "Failed to clone staging branch, trying main branch"
        retry_command "git clone --depth 500 '$MESA_FREEDESKTOP' '$BUILD_DIR/mesa'" "Cloning main branch"
    fi
}

clone_custom_commit() {
    log "Cloning for custom commit"
    
    if [ "$MESA_REPO_SOURCE" = "8gen" ]; then
        retry_command "git clone --depth=200 --branch '$MESA_8GEN_BRANCH' '$MESA_8GEN_SOURCE' '$BUILD_DIR/mesa'" "Cloning 8gen source"
    else
        retry_command "git clone --depth 500 '$MESA_FREEDESKTOP' '$BUILD_DIR/mesa'" "Cloning for custom commit"
    fi
    
    cd "$BUILD_DIR/mesa"
    
    if [ -n "$CUSTOM_COMMIT" ]; then
        log "Checking out custom commit: $CUSTOM_COMMIT"
        if git checkout "$CUSTOM_COMMIT" 2>/dev/null; then
            success "Checked out custom commit: $CUSTOM_COMMIT"
        else
            warn "Could not checkout $CUSTOM_COMMIT, fetching..."
            git fetch --depth=100 origin 2>/dev/null || true
            if git checkout "$CUSTOM_COMMIT" 2>/dev/null; then
                success "Checked out custom commit after fetch"
            else
                warn "Could not checkout $CUSTOM_COMMIT, using HEAD"
            fi
        fi
    fi
}

setup_mesa_repo() {
    cd "$BUILD_DIR/mesa"
    
    if [ "$MESA_REPO_SOURCE" = "8gen" ]; then
        apply_8gen_fixes
    fi
    
    git config user.name "BuildUser"
    git config user.email "build@system.local"
    
    COMMIT_HASH_SHORT=$(git rev-parse --short HEAD)
    MESA_VERSION=$(cat VERSION 2>/dev/null || echo "unknown")
    
    if [ "$MESA_VERSION" = "unknown" ]; then
        MESA_VERSION=$(git describe --tags --abbrev=0 2>/dev/null || echo "unknown")
    fi
    
    echo "$MESA_VERSION" > "$BUILD_DIR/version.txt"
    echo "$COMMIT_HASH_SHORT" > "$BUILD_DIR/commit.txt"
    success "Mesa ready: $MESA_VERSION ($COMMIT_HASH_SHORT)"
}

apply_8gen_fixes() {
    log "Applying 8gen compatibility fixes..."
    cd "$BUILD_DIR/mesa"

    if [ -f "src/freedreno/common/freedreno_devices.py" ]; then
        perl -i -p0e 's/(\n\s*a8xx_825)/,$1/s' src/freedreno/common/freedreno_devices.py 2>/dev/null || true
        sed -i '/REG_A8XX_GRAS_UNKNOWN_/d' src/freedreno/common/freedreno_devices.py 2>/dev/null || true
    fi

    find src/freedreno/vulkan -name "*.cc" -print0 2>/dev/null | \
        xargs -0 sed -i 's/ && (pdevice->info->chip != 8)//g' 2>/dev/null || true
    find src/freedreno/vulkan -name "*.cc" -print0 2>/dev/null | \
        xargs -0 sed -i 's/ && (pdevice->info->chip == 8)//g' 2>/dev/null || true

    success "8gen fixes applied"
}

# PREPARE BUILD DIR
prepare_build_dir() {
    header "Preparing Build Directory"
    mkdir -p "$BUILD_DIR"
    cd "$BUILD_DIR"

    setup_ndk
    clone_mesa

    cd "$BUILD_DIR"
    success "Build directory ready - Mesa $MESA_VERSION ($COMMIT_HASH_SHORT)"
}

# PATCH APPLICATION
apply_patch() {
    local patch_name="$1"
    local patch_file="$PATCHES_DIR/$patch_name"
    
    if [ ! -f "$patch_file" ]; then
        warn "Patch not found: $patch_file"
        return 1
    fi
    
    log "Applying patch: $patch_name"
    cd "$BUILD_DIR/mesa"
    
    if git apply "$patch_file" --check 2>/dev/null; then
        git apply "$patch_file"
        success "Patch applied: $patch_name"
        return 0
    else
        warn "Patch may not apply cleanly, trying 3-way merge..."
        if git apply "$patch_file" --3way 2>/dev/null; then
            success "Patch applied with 3-way merge: $patch_name"
            return 0
        else
            warn "Failed to apply patch: $patch_name"
            return 1
        fi
    fi
}

# BUILD SYSTEM
create_cross_file() {
    local NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
    local CROSS_FILE="$BUILD_DIR/cross_build"
    local NATIVE_FILE="$BUILD_DIR/native_build"

    cat <<EOF > "$CROSS_FILE"
[binaries]
ar = '$NDK_BIN/llvm-ar'
c = ['ccache', '$NDK_BIN/aarch64-linux-android${API_LEVEL}-clang']
cpp = ['ccache', '$NDK_BIN/aarch64-linux-android${API_LEVEL}-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-static-libstdc++']
c_ld = 'lld'
cpp_ld = 'lld'
strip = '$NDK_BIN/llvm-strip'
pkg-config = '/bin/false'

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'

[built-in options]
c_args = ['-O3', '-DNDEBUG', '-w', '-Wno-error']
cpp_args = ['-O3', '-DNDEBUG', '-w', '-Wno-error']
EOF

    cat <<EOF > "$NATIVE_FILE"
[binaries]
c = ['ccache', 'clang']
cpp = ['ccache', 'clang++']
pkg-config = '/usr/bin/pkg-config'
EOF

    info "Cross-compilation files created"
}

run_meson_setup() {
    local variant_name="$1"
    local log_file="$BUILD_DIR/meson_${variant_name}.log"

    log "Running Meson setup for $variant_name..."
    rm -rf build-release

    if ! meson setup build-release \
        --cross-file "$BUILD_DIR/cross_build" \
        --native-file "$BUILD_DIR/native_build" \
        -Dbuildtype=release \
        -Dplatforms=android \
        -Dplatform-sdk-version=$API_LEVEL \
        -Dandroid-stub=true \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dvulkan-beta=true \
        -Dvulkan-layers=device-select,overlay \
        -Dfreedreno-kmds=kgsl \
        -Db_lto=true \
        -Db_ndebug=true \
        -Dcpp_rtti=false \
        -Degl=disabled \
        -Dgbm=disabled \
        -Dglx=disabled \
        -Dopengl=false \
        -Dllvm=disabled \
        -Dlibunwind=disabled \
        -Dzstd=disabled \
        -Dwerror=false \
        -Dvalgrind=disabled \
        -Dbuild-tests=false \
        &> "$log_file"; then

        error "Meson setup failed. Check: $log_file"
    fi

    success "Meson setup complete"
}

run_ninja_build() {
    local variant_name="$1"
    local log_file="$BUILD_DIR/ninja_${variant_name}.log"
    local cores=$(nproc 2>/dev/null || echo 4)

    log "Building with Ninja ($cores cores)..."

    if ! ninja -C build-release -j"$cores" src/freedreno/vulkan/libvulkan_freedreno.so &> "$log_file"; then
        echo ""
        warn "Build failed. Last 50 lines:"
        tail -50 "$log_file"
        error "Ninja build failed for $variant_name"
    fi

    success "Build complete"
}

extract_vulkan_version() {
    cd "$BUILD_DIR/mesa"
    
    local vulkan_version="1.3.250"
    
    if [ -f "src/vulkan/util/vk_common.h" ]; then
        local vk_header_version=$(grep -o 'VK_HEADER_VERSION [0-9]*' src/vulkan/util/vk_common.h 2>/dev/null | head -1 | awk '{print $2}')
        if [ -n "$vk_header_version" ]; then
            local major=$((vk_header_version / 1000000))
            local minor=$(((vk_header_version % 1000000) / 1000))
            local patch=$((vk_header_version % 1000))
            vulkan_version="$major.$minor.$patch"
        fi
    elif [ -f "include/vulkan/vulkan_core.h" ]; then
        local vk_major=$(grep -o '#define VK_VERSION_MAJOR.*' include/vulkan/vulkan_core.h 2>/dev/null | head -1 | awk '{print $3}')
        local vk_minor=$(grep -o '#define VK_VERSION_MINOR.*' include/vulkan/vulkan_core.h 2>/dev/null | head -1 | awk '{print $3}')
        local vk_patch=$(grep -o '#define VK_VERSION_PATCH.*' include/vulkan/vulkan_core.h 2>/dev/null | head -1 | awk '{print $3}')
        if [ -n "$vk_major" ] && [ -n "$vk_minor" ]; then
            vulkan_version="$vk_major.$vk_minor.${vk_patch:-0}"
        fi
    fi
    
    echo "$vulkan_version"
}

generate_filename() {
    local variant_name="$1"
    local mesa_version="$2"
    local commit_short="$3"
    local naming_format="$4"
    
    local clean_version=$(echo "$mesa_version" | sed 's/[^0-9.]//g' | sed 's/\.$//g')
    
    while [[ "$clean_version" == *. ]]; do
        clean_version="${clean_version%.}"
    done
    
    if [ -z "$clean_version" ] || [ "$clean_version" = "unknown" ]; then
        clean_version=$(date +'%Y%m%d')
    fi
    
    case "$naming_format" in
        "emulator")
            if [ "$variant_name" = "gen8" ]; then
                echo "Turnip-Gen8-${clean_version}"
            else
                echo "Turnip-${clean_version}"
            fi
            ;;
        "simple")
            if [ "$variant_name" = "gen8" ]; then
                echo "Turnip-Gen8-${clean_version}"
            else
                echo "Turnip-A7xx-${clean_version}"
            fi
            ;;
        "detailed")
            local date_part=$(date +'%Y%m%d')
            if [ "$variant_name" = "gen8" ]; then
                echo "Turnip-Gen8-Mesa${clean_version}-${date_part}"
            else
                echo "Turnip-A7xx-Mesa${clean_version}-${date_part}"
            fi
            ;;
        *)
            echo "turnip-${variant_name}-${clean_version}-${commit_short}"
            ;;
    esac
}

package_build() {
    local variant_name="$1"
    local SO_FILE="build-release/src/freedreno/vulkan/libvulkan_freedreno.so"

    if [ ! -f "$SO_FILE" ]; then
        error "Build output not found: $SO_FILE"
    fi

    log "Packaging driver..."
    cd "$BUILD_DIR"

    local TEMP_DIR="driver_temp"
    rm -rf "$TEMP_DIR"
    mkdir -p "$TEMP_DIR"

    cp "mesa/$SO_FILE" "$TEMP_DIR/libvulkan.adreno.so"
    
    local VULKAN_VERSION=$(extract_vulkan_version)
    
    local DRIVER_NAME=$(generate_filename "$variant_name" "$MESA_VERSION" "$COMMIT_HASH_SHORT" "$NAMING_FORMAT")
    
    cat <<EOF > "$TEMP_DIR/meta.json"
{
    "schemaVersion": 1,
    "name": "Mesa Turnip Driver",
    "description": "Mesa ${MESA_VERSION} Built: ${BUILD_DATE}",
    "author": "Blue",
    "packageVersion": "1",
    "vendor": "Mesa3D",
    "driverVersion": "Vulkan ${VULKAN_VERSION}",
    "minApi": ${API_LEVEL},
    "libraryName": "libvulkan.adreno.so"
}
EOF

    cat <<EOF > "$TEMP_DIR/build_info.txt"
Build Date: ${BUILD_DATE}
Mesa Version: ${MESA_VERSION}
Vulkan Version: ${VULKAN_VERSION}
Commit Hash: ${COMMIT_HASH_SHORT}
Source Repository: ${MESA_REPO_SOURCE}
Source Type: ${MESA_SOURCE_TYPE}
Build Variant: ${variant_name}
Android API: ${API_LEVEL}
NDK Version: ${NDK_VERSION}
EOF

    cd "$TEMP_DIR"
    zip -9 "../${DRIVER_NAME}.zip" *
    cd ..
    
    rm -rf "$TEMP_DIR"
    
    local size=$(du -h "${DRIVER_NAME}.zip" | cut -f1)
    success "Created driver: ${DRIVER_NAME}.zip ($size)"
    info "Driver name: $DRIVER_NAME"
    info "Vulkan Version: ${VULKAN_VERSION}"
}

perform_build() {
    local variant_name="$1"

    header "Building: $variant_name"

    cd "$BUILD_DIR/mesa"
    create_cross_file
    run_meson_setup "$variant_name"
    run_ninja_build "$variant_name"
    package_build "$variant_name"
}

reset_mesa() {
    log "Resetting Mesa source..."
    cd "$BUILD_DIR/mesa"
    git checkout . 2>/dev/null || true
    git clean -fd 2>/dev/null || true
}

build_a7xx() {
    header "A7XX Build"
    reset_mesa
    
    # Apply patches
    apply_patch "memory_optimization.patch"
    apply_patch "sysmem_rendering.patch"
    apply_patch "compatibility_fixes.patch"
    
    perform_build "a7xx"
}

build_gen8() {
    header "Gen8 Build"
    reset_mesa
    
    # Apply patches
    apply_patch "sysmem_rendering.patch"
    apply_patch "compatibility_fixes.patch"
    
    perform_build "Gen8"
}

main() {
    echo ""
    info "Turnip Driver Build System"
    echo "--------------------------"
    info "Build Variant: $BUILD_VARIANT"
    info "Mesa Source: $MESA_REPO_SOURCE"
    info "Source Type: $MESA_SOURCE_TYPE"
    info "Build Date: $BUILD_DATE"
    echo ""

    check_dependencies
    prepare_build_dir

    case "$BUILD_VARIANT" in
        a7xx)
            build_a7xx
            ;;
        gen8)
            build_gen8
            ;;
        *)
            warn "Unknown variant: $BUILD_VARIANT"
            info "Available: a7xx, gen8"
            if [ "$MESA_REPO_SOURCE" = "8gen" ]; then
                warn "Defaulting to gen8..."
                build_gen8
            else
                warn "Defaulting to a7xx..."
                build_a7xx
            fi
            ;;
    esac

    echo ""
    success "Build Completed Successfully!"
    echo ""
    
    if ls "$BUILD_DIR"/*.zip 1>/dev/null 2>&1; then
        info "Output files:"
        ls -lh "$BUILD_DIR"/*.zip | awk '{print "  " $9 " (" $5 ")"}'
    else
        warn "No output files found"
        exit 1
    fi
}

main "$@"
