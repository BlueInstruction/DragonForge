# Mesa Turnip Driver for Android Emulators

This repository provides build scripts and configurations to compile the Mesa Turnip Vulkan driver for Adreno GPUs, specifically tailored for use with Android emulators like Winlator Cmod.

## Features

*   Builds Mesa 25.3.3 with the Turnip driver.
*   Targets Adreno 6xx and 7xx series GPUs.
*   Includes performance optimizations for Adreno 7xx/750 in emulated environments.
*   Packages the output as a ZIP file containing `vulkan.ad07xx.so` and `meta.json`.

## Contents

*   `.github/workflows/build_turnip.yml`: GitHub Actions workflow for automated builds.
*   `scripts/build_turnip`: Standalone build script for local compilation.
*   `000001.patch`: Optional patch file for emulator-specific changes (example included).
*   `android-aarch64`: Meson cross-compilation file for AArch64 Android.
*   `.gitignore`: Standard git ignore rules.
*   `LICENSE`: MIT License file.
*   `README.md`: This file.

## Usage

### Automated Build (GitHub Actions)

Push your changes to the `main` branch. The workflow will automatically trigger, build the driver, and create a release with the ZIP file attached.

### Local Build

1.  Ensure you have the Android NDK installed and its `bin` directory in your `PATH`.
2.  Install Meson, Ninja, and other required build dependencies.
3.  Run the build script: `./scripts/build_turnip`
4.  The resulting `MesaTurnipDriver-v25.3.3.zip` file will be created in the root directory.
