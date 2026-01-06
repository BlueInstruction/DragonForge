#!/usr/bin/env bash
set -e

# Configuration
MESA_VERSION="mesa-25.3.3"
MESA_URL="https://gitlab.freedesktop.org/mesa/mesa.git"
BUILD_DIR="build-android"
OUTPUT_DIR="build_output"
ANDROID_API_LEVEL="29"

echo ">>> [1/6] Preparing Build Environment..."
mkdir -p "$OUTPUT_DIR"
rm -rf mesa "$BUILD_DIR"

echo ">>> [2/6] Cloning Mesa ($MESA_VERSION)..."
git clone --depth 1 --branch "$MESA_VERSION" "$MESA_URL" mesa

echo ">>> [3/6] Applying Turnip patch..."
cd mesa

if [ ! -f "../patches/0001-tu-env-overrides.patch" ]; then
    echo "ERROR: Patch file not found: patches/0001-tu-env-overrides.patch"
    exit 1
fi

git apply --3way ../patches/0001-tu-env-overrides.patch

cd ..

echo ">>> [4/6] Configuring Meson..."

if [ ! -f "android-aarch64" ]; then
    echo "ERROR: Cross file 'android-aarch64' not found in repository root."
    exit 1
fi

cp android-aarch64 mesa/
cd mesa

meson setup "$BUILD_DIR" \
    --cross-file android-aarch64 \
    --buildtype=release \
    -Dplatforms=android \
    -Dplatform-sdk-version="$ANDROID_API_LEVEL" \
    -Dandroid-stub=true \
    -Dgallium-drivers= \
    -Dvulkan-drivers=freedreno \
    -Dfreedreno-kmds=kgsl \
    -Db_lto=true \
    -Doptimization=3 \
    -Dstrip=true \
    -Dllvm=disabled

echo ">>> [5/6] Compiling..."
ninja -C "$BUILD_DIR"

echo ">>> [6/6] Packaging Artifacts..."
DRIVER_LIB=$(find "$BUILD_DIR" -name "libvulkan_freedreno.so" | head -n 1)

if [ -z "$DRIVER_LIB" ]; then
    echo "ERROR: libvulkan_freedreno.so not found."
    exit 1
fi

cp "$DRIVER_LIB" ../"$OUTPUT_DIR"/vulkan.ad07xx.so

cd ../"$OUTPUT_DIR"

cat <<EOF > meta.json
{
  "name": "Turnip v25.3.3 - Adreno 750 Optimized",
  "version": "25.3.3",
  "description": "Custom A750 build with Turnip environment overrides.",
  "library": "vulkan.ad07xx.so"
}
EOF

zip -r turnip_adreno750_optimized.zip vulkan.ad07xx.so meta.json

echo ">>> Build Complete."
