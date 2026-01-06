# Mesa Turnip Driver - Adreno 750 Optimized Build

This repository provides a **custom build of the Turnip Vulkan driver** for Adreno 7xx GPUs, optimized specifically for Android devices using **Mesa 25.3.3**.

## Features

- Environment overrides to enable:
  - UBWC hints (`FD_DEV_FEATURES`)
  - Large shader cache (`MESA_SHADER_CACHE_MAX_SIZE=1024M`)
  - Force unaligned device-local memory (`TU_DEBUG`)
- Optimized build flags for **Adreno 750** (`-O3`, `-march=armv8.5-a`, `-mtune=cortex-x4`)
- Full **cross-compilation support** for Android API level 29
- Packaged output with `vulkan.ad07xx.so` and metadata for easy integration

## Repository Structure
