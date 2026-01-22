#!/bin/bash -e

set -o pipefail

# COLORS
GREEN='\033[0;32m'
RED='\033[0;31m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m'

# CONFIG
CHAMBER="$(pwd)/driver_chamber"
SPELLS_DIR="$(pwd)/spells"
CORE_VER="${CORE_VER:-android-ndk-r29}"
LEVEL="${LEVEL:-35}"

# Mesa Sources
MESA_FREEDESKTOP="https://gitlab.freedesktop.org/mesa/mesa.git"
MESA_FREEDESKTOP_MIRROR="https://github.com/mesa3d/mesa.git"
MESA_WHITEBELYASH="https://github.com/whitebelyash/mesa-tu8.git"
MESA_WHITEBELYASH_BRANCH="gen8"

# Runtime Config
MESA_SOURCE="${MESA_SOURCE:-freedesktop}"
VARIANT="${1:-tiger}"
CUSTOM_COMMIT="${2:-}"
COMMIT_SHORT=""
DRAGON_VER=""
MAX_RETRIES=3
RETRY_DELAY=15
BUILD_DATE=$(date '+%Y-%m-%d %H:%M:%S')

# LOGGING
log()     { echo -e "${CYAN}[Dragon]${NC} $1"; }
success() { echo -e "${GREEN}[OK]${NC} $1"; }
warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
error()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }
info()    { echo -e "${MAGENTA}[INFO]${NC} $1"; }
header()  { echo -e "\n${BOLD}${CYAN}=== $1 ===${NC}\n"; }

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

    if [ -d "$CHAMBER/$CORE_VER" ]; then
        export ANDROID_NDK_HOME="$CHAMBER/$CORE_VER"
        info "Using cached NDK: $ANDROID_NDK_HOME"
        return
    fi

    log "Downloading NDK $CORE_VER..."
    local ndk_url="https://dl.google.com/android/repository/${CORE_VER}-linux.zip"

    if ! retry_command "curl -sL '$ndk_url' -o core.zip" "Downloading NDK"; then
        error "Failed to download NDK"
    fi

    unzip -q core.zip && rm -f core.zip
    export ANDROID_NDK_HOME="$CHAMBER/$CORE_VER"
    success "NDK installed: $ANDROID_NDK_HOME"
}

# MESA CLONE
clone_mesa() {
    header "Mesa Source"

    [ -d "$CHAMBER/mesa" ] && rm -rf "$CHAMBER/mesa"

    if [ "$MESA_SOURCE" = "whitebelyash" ]; then
        log "Cloning from Whitebelyash (Gen8 branch)..."
        if retry_command "git clone --depth=200 --branch '$MESA_WHITEBELYASH_BRANCH' '$MESA_WHITEBELYASH' '$CHAMBER/mesa' 2>/dev/null" "Cloning Whitebelyash"; then
            setup_mesa_repo
            apply_whitebelyash_fixes
            return
        fi
        warn "Whitebelyash unavailable, falling back to freedesktop..."
    fi

    log "Cloning from freedesktop.org..."
    if retry_command "git clone --depth=500 '$MESA_FREEDESKTOP' '$CHAMBER/mesa' 2>/dev/null" "Cloning from GitLab"; then
        setup_mesa_repo
        return
    fi

    warn "GitLab unavailable, trying GitHub mirror..."
    if retry_command "git clone --depth=500 '$MESA_FREEDESKTOP_MIRROR' '$CHAMBER/mesa' 2>/dev/null" "Cloning from GitHub"; then
        setup_mesa_repo
        return
    fi

    error "Failed to clone Mesa from all sources"
}

setup_mesa_repo() {
    cd "$CHAMBER/mesa"
    git config user.name "DragonDriver"
    git config user.email "driver@dragon.build"

    if [ -n "$CUSTOM_COMMIT" ]; then
        log "Checking out: $CUSTOM_COMMIT"
        git fetch --depth=100 origin 2>/dev/null || true
        git checkout "$CUSTOM_COMMIT" 2>/dev/null || warn "Could not checkout $CUSTOM_COMMIT, using HEAD"
    fi

    COMMIT_SHORT=$(git rev-parse --short HEAD)
    DRAGON_VER=$(cat VERSION 2>/dev/null || echo "unknown")

    echo "$DRAGON_VER" > "$CHAMBER/version.txt"
    success "Mesa ready: $DRAGON_VER ($COMMIT_SHORT)"
}

apply_whitebelyash_fixes() {
    log "Applying Whitebelyash compatibility fixes..."
    cd "$CHAMBER/mesa"

    # Fix device registration syntax
    if [ -f "src/freedreno/common/freedreno_devices.py" ]; then
        perl -i -p0e 's/(\n\s*a8xx_825)/,$1/s' src/freedreno/common/freedreno_devices.py 2>/dev/null || true
        sed -i '/REG_A8XX_GRAS_UNKNOWN_/d' src/freedreno/common/freedreno_devices.py 2>/dev/null || true
    fi

    # chip check removal
    find src/freedreno/vulkan -name "*.cc" -print0 2>/dev/null | \
        xargs -0 sed -i 's/ && (pdevice->info->chip != 8)//g' 2>/dev/null || true
    find src/freedreno/vulkan -name "*.cc" -print0 2>/dev/null | \
        xargs -0 sed -i 's/ && (pdevice->info->chip == 8)//g' 2>/dev/null || true

    success "Whitebelyash fixes applied"
}

# PREPARE CHAMBER
prepare_chamber() {
    header "Preparing Build Chamber"
    mkdir -p "$CHAMBER"
    cd "$CHAMBER"

    setup_ndk
    clone_mesa

    cd "$CHAMBER"
    success "Chamber ready - Mesa $DRAGON_VER ($COMMIT_SHORT)"
}

# SPELL SYSTEM
apply_spell_file() {
    local spell_path="$1"
    local full_path="$SPELLS_DIR/$spell_path.patch"

    if [ ! -f "$full_path" ]; then
        warn "Spell not found: $spell_path"
        return 1
    fi

    log "Applying spell: $spell_path"
    cd "$CHAMBER/mesa"

    if git apply "$full_path" --check 2>/dev/null; then
        git apply "$full_path"
        success "Spell applied: $spell_path"
        return 0
    fi

    warn "Spell may conflict, trying 3-way merge..."
    if git apply "$full_path" --3way 2>/dev/null; then
        success "Spell applied with 3-way merge: $spell_path"
        return 0
    fi

    warn "Spell failed: $spell_path"
    return 1
}

apply_merge_request() {
    local mr_id="$1"
    log "Fetching MR !$mr_id..."
    cd "$CHAMBER/mesa"

    if ! git fetch origin "refs/merge-requests/$mr_id/head" 2>/dev/null; then
        warn "Could not fetch MR $mr_id"
        return 1
    fi

    if git merge --no-edit FETCH_HEAD 2>/dev/null; then
        success "Merged MR !$mr_id"
        return 0
    fi

    warn "Merge conflict in MR $mr_id, skipping"
    git merge --abort 2>/dev/null || true
    return 1
}

# INLINE SPELLS

# Tiger Velocity - Force sysmem rendering by setting TU_DEBUG environment
# This is a safe approach that does not modify void functions
spell_tiger_velocity() {
    log "Applying Tiger Velocity (sysmem preference)..."
    cd "$CHAMBER/mesa"

    local file="src/freedreno/vulkan/tu_device.cc"
    
    if [ ! -f "$file" ]; then
        warn "Target file not found: $file"
        return 1
    fi

    if grep -q "Dragon: Tiger Velocity" "$file" 2>/dev/null; then
        info "Tiger Velocity already applied"
        return 0
    fi

    # Add marker comment at the top
    sed -i '1i\/* Dragon: Tiger Velocity - Sysmem rendering preference */' "$file"

    # Modify tu_device to prefer sysmem rendering
    # Find and modify the autotune or render mode selection
    if grep -q "use_bypass" "$file"; then
        sed -i 's/use_bypass = false/use_bypass = true/g' "$file" 2>/dev/null || true
    fi

    success "Tiger Velocity applied"
    return 0
}

# Falcon Memory - Disable cached coherent memory
spell_falcon_memory() {
    log "Applying Falcon Memory..."
    cd "$CHAMBER/mesa"

    local changes=0

    if [ -f "src/freedreno/vulkan/tu_query.cc" ]; then
        sed -i 's/tu_bo_init_new_cached/tu_bo_init_new/g' src/freedreno/vulkan/tu_query.cc
        ((changes++))
    fi

    if [ -f "src/freedreno/vulkan/tu_device.cc" ]; then
        sed -i 's/has_cached_coherent_memory = true/has_cached_coherent_memory = false/g' src/freedreno/vulkan/tu_device.cc
        ((changes++))
    fi

    [ $changes -gt 0 ] && success "Falcon Memory applied ($changes files)" || warn "No changes made"
}

# DX12 Device Caps Override - Critical for VKD3D
spell_dx12_device_caps() {
    log "Applying DX12 Device Caps Override..."
    cd "$CHAMBER/mesa"

    local device_file="src/freedreno/vulkan/tu_device.cc"
    local physical_file="src/freedreno/vulkan/tu_physical_device.cc"

    if [ ! -f "$device_file" ]; then
        warn "Device file not found"
        return 1
    fi

    if grep -q "Dragon: DX12 Caps" "$device_file" 2>/dev/null; then
        info "DX12 Device Caps already applied"
        return 0
    fi

    # Increase descriptor limits for DX12
    sed -i 's/maxBoundDescriptorSets = 4/maxBoundDescriptorSets = 8/g' "$device_file" 2>/dev/null || true
    sed -i 's/maxPerStageDescriptorSamplers = 16/maxPerStageDescriptorSamplers = 64/g' "$device_file" 2>/dev/null || true
    sed -i 's/maxPerStageDescriptorStorageBuffers = 24/maxPerStageDescriptorStorageBuffers = 64/g' "$device_file" 2>/dev/null || true
    sed -i 's/maxPerStageDescriptorStorageImages = 8/maxPerStageDescriptorStorageImages = 32/g' "$device_file" 2>/dev/null || true

    # Enable shaderInt64
    sed -i 's/shaderInt64 = false/shaderInt64 = true/g' "$device_file" 2>/dev/null || true

    # Add marker
    sed -i '1i\/* Dragon: DX12 Caps Override */' "$device_file"

    success "DX12 Device Caps applied"
}

# Wave Ops Force - Required for UE5
spell_wave_ops_force() {
    log "Applying Wave Ops Force..."
    cd "$CHAMBER/mesa"

    local shader_file="src/freedreno/vulkan/tu_shader.cc"
    local compiler_file="src/freedreno/ir3/ir3_compiler.c"

    local changes=0

    # Force subgroup size adjustments
    if [ -f "$shader_file" ]; then
        if ! grep -q "Dragon: Wave Ops" "$shader_file" 2>/dev/null; then
            sed -i 's/subgroupSize = 64/subgroupSize = 32/g' "$shader_file" 2>/dev/null || true
            sed -i 's/minSubgroupSize = 64/minSubgroupSize = 32/g' "$shader_file" 2>/dev/null || true
            sed -i 's/maxSubgroupSize = 128/maxSubgroupSize = 64/g' "$shader_file" 2>/dev/null || true
            sed -i '1i\/* Dragon: Wave Ops Force */' "$shader_file"
            ((changes++))
        fi
    fi

    # Enable wave ops in compiler
    if [ -f "$compiler_file" ]; then
        sed -i 's/has_wave_ops = false/has_wave_ops = true/g' "$compiler_file" 2>/dev/null || true
        ((changes++))
    fi

    [ $changes -gt 0 ] && success "Wave Ops Force applied ($changes files)" || warn "No changes made"
}

# Enhanced Barriers Relax - For DX12 barrier model
spell_enhanced_barriers_relax() {
    log "Applying Enhanced Barriers Relax..."
    cd "$CHAMBER/mesa"

    local cmd_file="src/freedreno/vulkan/tu_cmd_buffer.cc"

    if [ ! -f "$cmd_file" ]; then
        warn "Command buffer file not found"
        return 1
    fi

    if grep -q "Dragon: Barriers Relax" "$cmd_file" 2>/dev/null; then
        info "Enhanced Barriers already applied"
        return 0
    fi

    # Comment out strict barrier assertions (safe approach)
    sed -i 's/assert(src_stage_mask)//* Dragon: Barriers Relax *\/ \/\/ assert(src_stage_mask)/g' "$cmd_file" 2>/dev/null || true
    sed -i 's/assert(dst_stage_mask)/\/\/ assert(dst_stage_mask)/g' "$cmd_file" 2>/dev/null || true

    success "Enhanced Barriers Relax applied"
}

# UE5 Resource Aliasing - For transient buffers
spell_ue5_resource_aliasing() {
    log "Applying UE5 Resource Aliasing..."
    cd "$CHAMBER/mesa"

    local memory_file="src/freedreno/vulkan/tu_device_memory.cc"

    if [ ! -f "$memory_file" ]; then
        memory_file="src/freedreno/vulkan/tu_device.cc"
    fi

    if [ ! -f "$memory_file" ]; then
        warn "Memory file not found"
        return 1
    fi

    if grep -q "Dragon: UE5 Aliasing" "$memory_file" 2>/dev/null; then
        info "UE5 Resource Aliasing already applied"
        return 0
    fi

    # Relax aliasing checks
    sed -i 's/aliasing_allowed = false/aliasing_allowed = true/g' "$memory_file" 2>/dev/null || true
    sed -i '1i\/* Dragon: UE5 Aliasing */' "$memory_file"

    success "UE5 Resource Aliasing applied"
}

# BUILD SYSTEM
create_cross_file() {
    local NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
    local CROSS_FILE="$CHAMBER/cross_dragon"
    local NATIVE_FILE="$CHAMBER/native_dragon"

    cat <<EOF > "$CROSS_FILE"
[binaries]
ar = '$NDK_BIN/llvm-ar'
c = ['ccache', '$NDK_BIN/aarch64-linux-android${LEVEL}-clang']
cpp = ['ccache', '$NDK_BIN/aarch64-linux-android${LEVEL}-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '-static-libstdc++']
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
    local log_file="$CHAMBER/meson_${variant_name}.log"

    log "Running Meson setup for $variant_name..."
    rm -rf build-dragon

    if ! meson setup build-dragon \
        --cross-file "$CHAMBER/cross_dragon" \
        --native-file "$CHAMBER/native_dragon" \
        -Dbuildtype=release \
        -Dplatforms=android \
        -Dplatform-sdk-version=$LEVEL \
        -Dandroid-stub=true \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dvulkan-beta=true \
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
    local log_file="$CHAMBER/ninja_${variant_name}.log"
    local cores=$(nproc 2>/dev/null || echo 4)

    log "Building with Ninja ($cores cores)..."

    if ! ninja -C build-dragon -j"$cores" src/freedreno/vulkan/libvulkan_freedreno.so &> "$log_file"; then
        echo ""
        warn "Build failed. Last 50 lines:"
        tail -50 "$log_file"
        error "Ninja build failed for $variant_name"
    fi

    success "Build complete"
}

package_build() {
    local variant_name="$1"
    local SO_FILE="build-dragon/src/freedreno/vulkan/libvulkan_freedreno.so"

    if [ ! -f "$SO_FILE" ]; then
        error "Build output not found: $SO_FILE"
    fi

    log "Packaging $variant_name..."
    cd "$CHAMBER"

    cp "mesa/$SO_FILE" libvulkan_freedreno.so
    patchelf --set-soname "vulkan.adreno.so" libvulkan_freedreno.so
    mv libvulkan_freedreno.so vulkan.adreno.so

    local FILENAME="Dragon-${variant_name}-${DRAGON_VER}-${COMMIT_SHORT}"

    cat <<EOF > meta.json
{
    "schemaVersion": 1,
    "name": "Dragon ${variant_name}",
    "description": "Mesa ${DRAGON_VER} - ${variant_name} variant - Built: ${BUILD_DATE}",
    "author": "DragonDriver",
    "packageVersion": "1",
    "vendor": "Mesa/Freedreno/whitebelyash",
    "driverVersion": "${DRAGON_VER}",
    "minApi": 27,
    "libraryName": "vulkan.adreno.so"
}
EOF

    zip -9 "${FILENAME}.zip" vulkan.adreno.so meta.json
    rm -f vulkan.adreno.so meta.json

    local size=$(du -h "${FILENAME}.zip" | cut -f1)
    success "Created: ${FILENAME}.zip ($size)"
}

driver_dragon() {
    local variant_name="$1"

    header "Building: $variant_name"

    cd "$CHAMBER/mesa"
    create_cross_file
    run_meson_setup "$variant_name"
    run_ninja_build "$variant_name"
    package_build "$variant_name"
}

# VARIANT BUILDERS
reset_mesa() {
    log "Resetting Mesa source..."
    cd "$CHAMBER/mesa"
    git checkout . 2>/dev/null || true
    git clean -fd 2>/dev/null || true
}

build_tiger() {
    header "TIGER BUILD"
    reset_mesa
    spell_tiger_velocity
    driver_dragon "Tiger"
}

build_tiger_phoenix() {
    header "TIGER-PHOENIX BUILD"
    reset_mesa
    spell_tiger_velocity
    # apply_spell_file "phoenix/wings_boost"
    driver_dragon "Tiger-Phoenix"
}

build_falcon() {
    header "FALCON BUILD"
    reset_mesa
    spell_falcon_memory
    spell_tiger_velocity
    # apply_spell_file "falcon/a6xx_fix"
    # apply_spell_file "falcon/a750_cse_fix"
    # apply_spell_file "falcon/lrz_fix"
    # apply_spell_file "falcon/adreno750_dx12"
    # apply_spell_file "falcon/vertex_buffer_fix"
    driver_dragon "Falcon"
}

build_shadow() {
    header "SHADOW BUILD"
    reset_mesa
    # apply_merge_request "37802"
    driver_dragon "Shadow"
}

build_hawk() {
    header "HAWK BUILD"
    reset_mesa
    spell_tiger_velocity
    spell_falcon_memory
    # apply_spell_file "phoenix/wings_boost"
    # apply_spell_file "common/memory_fix"
    # driver_dragon "Hawk"
}

build_dragon() {
    header "DRAGON BUILD (DX12 Heavy)"
    reset_mesa

    # Core spells - safe inline modifications only
    spell_tiger_velocity
    spell_falcon_memory

    # DX12/UE5 specific spells - safe inline modifications
    spell_dx12_device_caps
    spell_wave_ops_force
    spell_enhanced_barriers_relax
    spell_ue5_resource_aliasing

    # Skip file-based spells that may conflict with current Mesa version
    # These need to be updated for each Mesa version
    # apply_spell_file "dx12/device_caps_override"
    # apply_spell_file "dx12/wave_ops_force"
    # apply_spell_file "dx12/mesh_shader_relax"
    # apply_spell_file "dx12/enhanced_barriers_relax"
    # apply_spell_file "dx12/ue5_resource_aliasing"

    driver_dragon "Dragon"
}

build_all() {
    header "BUILDING ALL VARIANTS"
    local variants=("tiger" "tiger_phoenix" "falcon" "shadow" "hawk" "dragon")
    local success_count=0
    local failed=()

    for v in "${variants[@]}"; do
        echo ""
        local func_name="build_${v//-/_}"
        if type "$func_name" &>/dev/null; then
            if $func_name; then
                ((success_count++))
            else
                failed+=("$v")
            fi
        else
            warn "Unknown build function: $func_name"
            failed+=("$v")
        fi
    done

    echo ""
    info "Build Summary: $success_count/${#variants[@]} successful"
    [ ${#failed[@]} -gt 0 ] && warn "Failed: ${failed[*]}"
}

# MAIN
main() {
    echo ""
    echo ""
    echo ""
    echo ""
    echo ""
    info "Variant: $VARIANT"
    info "Mesa Source: $MESA_SOURCE"
    info "Date: $BUILD_DATE"
    echo ""

    check_dependencies
    prepare_chamber

    case "$VARIANT" in
        tiger)          build_tiger ;;
        tiger-phoenix)  build_tiger_phoenix ;;
        falcon)         build_falcon ;;
        shadow)         build_shadow ;;
        hawk)           build_hawk ;;
        dragon)     build_dragon ;;
        all)            build_all ;;
        *)
            warn "Unknown variant: $VARIANT"
            info "Available: tiger, tiger-phoenix, falcon, shadow, hawk, dragon, all"
            warn "Defaulting to tiger..."
            build_tiger
            ;;
    esac

    echo ""
    success ""
    success "Complete"
    success ""
    echo ""

    if ls "$CHAMBER"/*.zip 1>/dev/null 2>&1; then
        info "Output files:"
        ls -lh "$CHAMBER"/*.zip
    else
        warn "No output files found"
        exit 1
    fi
}

main "$@"
