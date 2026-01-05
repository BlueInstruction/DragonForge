#!/usr/bin/env bash
set -e

# Clone your repository if not present
if [ ! -d "MesaTurnipDriver" ]; then
    git clone https://github.com/BlueInstruction/MesaTurnipDriver.git
fi
cd MesaTurnipDriver

# Create directories
mkdir -p .github/workflows
mkdir -p tools
mkdir -p configs

# Create install-best-driver.sh with latest updates
cat > install-best-driver.sh << 'EOF'
#!/usr/bin/env bash
set -e

echo "========================================"
echo "最佳 PC 模擬器驅動程式安裝工具"
echo "專為 Adreno 750 優化"
echo "========================================"

# 檢查 root 權限
if [ "$(whoami)" != "root" ]; then
    echo "錯誤: 需要 root 權限執行此腳本"
    echo "請使用 'su' 切換到 root"
    exit 1
fi

# 設備檢測
DEVICE=$(getprop ro.product.model)
GPU=$(getprop ro.hardware.egl)
RAM=$(cat /proc/meminfo | grep MemTotal | awk '{print $2}')
RAM_GB=$((RAM / 1048576))

echo "檢測設備: $DEVICE"
echo "GPU: $GPU"
echo "RAM: ${RAM_GB}GB"

if [[ ! "$GPU" =~ "adreno" ]] && [[ ! "$GPU" =~ "Adreno" ]]; then
    echo "警告: 未檢測到 Adreno GPU，驅動程式可能不兼容"
    read -p "是否繼續? (y/n): " -n 1 -r
    echo
    if [[ ! \( REPLY =~ ^[Yy] \) ]]; then
        exit 1
    fi
fi

# 創建工作目錄
WORKDIR="/data/local/tmp/turnip_install"
BACKUP_DIR="/data/local/tmp/turnip_backup_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$WORKDIR"
mkdir -p "$BACKUP_DIR"

# 備份現有驅動
backup_existing_driver() {
    echo "備份現有驅動程式..."
    
    # 備份 Vulkan 驅動
    for path in "/vendor/lib64/hw/" "/vendor/lib/hw/"; do
        for driver in "vulkan.adreno.so" "vulkan.msm.so" "vulkan.qcom.so"; do
            if [ -f "\( {path} \){driver}" ]; then
                cp "\( {path} \){driver}" "\( {BACKUP_DIR}/ \)(basename \( {driver})_ \)(date +%s)"
                echo "備份: \( {path} \){driver}"
            fi
        done
    done
    
    # 備份 OpenGL ES 驅動
    for driver in "egl" "gpu"; do
        for ext in "so" "so.bak"; do
            if [ -f "/vendor/lib64/lib\( {driver}. \){ext}" ]; then
                cp "/vendor/lib64/lib\( {driver}. \){ext}" "${BACKUP_DIR}/"
            fi
            if [ -f "/vendor/lib/lib\( {driver}. \){ext}" ]; then
                cp "/vendor/lib/lib\( {driver}. \){ext}" "${BACKUP_DIR}/"
            fi
        done
    done
    
    echo "備份完成，存儲在: $BACKUP_DIR"
}

# 下載最佳驅動程式版本
download_best_driver() {
    echo "下載最佳驅動程式..."
    
    # 根據設備選擇最佳驅動程式 (使用最新 v26.0.0-rc07 性能修復版本)
    if [[ "$GPU" =~ "750" ]] || [[ "$DEVICE" =~ "8 Gen 3" ]]; then
        echo "檢測到 Adreno 750 設備，使用 v26.0.0-rc07 優化版本"
        DRIVER_URL="https://github.com/K11MCH1/AdrenoToolsDrivers/releases/download/v26.0.0-rc07/Turnip_v26.0.0_R3_CB_Perf_Fix.so"
    elif [[ "$GPU" =~ "740" ]] || [[ "$DEVICE" =~ "8 Gen 2" ]]; then
        echo "檢測到 Adreno 740 設備"
        DRIVER_URL="https://github.com/K11MCH1/AdrenoToolsDrivers/releases/download/v26.0.0-rc07/Turnip_v26.0.0_R3_CB_Perf_Fix.so"
    else
        echo "使用通用 Adreno 7xx 驅動程式"
        DRIVER_URL="https://github.com/K11MCH1/AdrenoToolsDrivers/releases/download/v26.0.0-rc07/Turnip_v26.0.0_R3_CB_Perf_Fix.so"
    fi
    
    # 下載驅動程式
    if command -v wget > /dev/null; then
        wget -O "$WORKDIR/vulkan.adreno.so" "$DRIVER_URL"
    elif command -v curl > /dev/null; then
        curl -L -o "$WORKDIR/vulkan.adreno.so" "$DRIVER_URL"
    else
        echo "錯誤: 需要 wget 或 curl"
        exit 1
    fi
    
    # 驗證下載
    if [ ! -f "$WORKDIR/vulkan.adreno.so" ]; then
        echo "錯誤: 驅動程式下載失敗"
        exit 1
    fi
    
    # 檢查驅動程式有效性
    if ! strings "$WORKDIR/vulkan.adreno.so" | grep -q "Mesa\|Turnip"; then
        echo "警告: 下載的文件可能不是有效的 Vulkan 驅動程式"
    fi
    
    echo "驅動程式下載完成: $(ls -lh $WORKDIR/vulkan.adreno.so)"
}

# 安裝驅動程式
install_driver() {
    echo "安裝驅動程式..."
    
    # 查找正確的安裝路徑
    if [ -d "/vendor/lib64/hw" ]; then
        INSTALL_PATH="/vendor/lib64/hw/vulkan.adreno.so"
        echo "安裝到 64-bit 路徑: $INSTALL_PATH"
    elif [ -d "/vendor/lib/hw" ]; then
        INSTALL_PATH="/vendor/lib/hw/vulkan.adreno.so"
        echo "安裝到 32-bit 路徑: $INSTALL_PATH"
    else
        echo "錯誤: 找不到驅動程式安裝目錄"
        exit 1
    fi
    
    # 備份原始驅動
    if [ -f "$INSTALL_PATH" ]; then
        cp "\( INSTALL_PATH" " \){INSTALL_PATH}.backup"
        echo "已備份原始驅動: ${INSTALL_PATH}.backup"
    fi
    
    # 複製新驅動
    cp "$WORKDIR/vulkan.adreno.so" "$INSTALL_PATH"
    
    # 設置權限
    chmod 644 "$INSTALL_PATH"
    chown root:root "$INSTALL_PATH"
    
    # 設置 SELinux 上下文
    if command -v chcon > /dev/null; then
        chcon u:object_r:vendor_file:s0 "$INSTALL_PATH"
    fi
    
    echo "驅動程式安裝完成"
}

# 創建優化配置
create_optimized_config() {
    echo "創建優化配置..."
    
    # 基礎配置
    cat > /data/local/tmp/turnip_config.sh << 'EOF'
#!/system/bin/sh
# Turnip Adreno 750 最佳性能配置

# 基礎性能設置
export MESA_SHADER_CACHE_MAX_SIZE=2147483648
export MESA_SHADER_CACHE_DISABLE=false
export MESA_GLTHREAD=true
export MESA_VK_VERSION_OVERRIDE=1.4.335

# Turnip 調試和優化設置
export TU_DEBUG=noconform,perfc,flushall,syncdraw
export TU_PERF=nobinning
export TU_I_PREFER_BANDING=0

# Vulkan 設置
export VK_ICD_FILENAMES=/vendor/lib64/hw/vulkan.adreno.so:/vendor/lib/hw/vulkan.adreno.so
export VK_LOADER_DEBUG=error,warn

# 遊戲特定優化
# 通用設置
export FD_DEV_FEATURES=enable_tp_ubwc_flag_hint=1
export MESA_VK_WSI_PRESENT_MODE=mailbox
export MESA_VK_SYNC_FENCES=true
export MESA_VK_ASYNC_COMPUTE=true

# 減少著色器編譯卡頓
export MESA_VK_DISABLE_PIPELINE_CACHE=false
export MESA_VK_PIPELINE_CACHE_SIZE=512

# 提高紋理質量
export MESA_VK_TEXTURE_LOD_BIAS=0.0
export MESA_VK_ANISOTROPIC_FILTERING=16

# 線程優化
export MESA_VK_NUM_THREADS=4
export MESA_VK_PARALLEL_COMPILE=true

echo "Turnip 驅動程式配置已加載"
EOF
    
    # 創建遊戲特定配置
    cat > /data/local/tmp/game_profiles.sh << 'EOF'
#!/system/bin/sh
# 遊戲特定優化配置

set_turnip_profile() {
    case "$1" in
        "horizon"|"horizon zero dawn")
            export TU_DEBUG=noconform,perfc,flushall,forcebin
            export FD_DEV_FEATURES=enable_tp_ubwc_flag_hint=1,disable_prim_gmem_banding=1
            export MESA_VK_PIPELINE_CACHE_SIZE=768
            echo "已設置 Horizon Zero Dawn 優化配置"
            ;;
            
        "valhalla"|"assassin's creed valhalla")
            export TU_DEBUG=perfc,syncdraw,flushall,nobin
            export MESA_SHADER_CACHE_MAX_SIZE=3221225472
            export MESA_VK_PIPELINE_CACHE_SIZE=1024
            echo "已設置 Assassin's Creed Valhalla 優化配置"
            ;;
            
        "elden"|"elden ring")
            export TU_DEBUG=perfc,syncdraw,nobin,flushall
            export MESA_VK_SYNC_FENCES=true
            export MESA_VK_ASYNC_COMPUTE=true
            echo "已設置 Elden Ring 優化配置"
            ;;
            
        "spiderman"|"spider-man")
            export TU_DEBUG=perfc,flushall,dynamic,forcebin
            export MESA_VK_PIPELINE_CACHE_SIZE=512
            export MESA_VK_PRESENT_MODE=immediate
            echo "已設置 Spider-Man 優化配置"
            ;;
            
        "gow"|"god of war")
            export TU_DEBUG=perfc,syncdraw,flushall
            export MESA_VK_SYNC_FENCES=true
            export MESA_VK_NUM_THREADS=6
            echo "已設置 God of War 優化配置"
            ;;
            
        "tsushima"|"ghost of tsushima")
            export TU_DEBUG=noconform,perfc,flushall,forcebin
            export FD_DEV_FEATURES=enable_tp_ubwc_flag_hint=1
            export MESA_VK_WSI_PRESENT_MODE=mailbox
            echo "已設置 Ghost of Tsushima 優化配置"
            ;;
            
        "fifa"|"fifa 23")
            export TU_DEBUG=perfc,flushall,dynamic
            export MESA_VK_PIPELINE_CACHE_SIZE=256
            export MESA_VK_PRESENT_MODE=fifo
            echo "已設置 FIFA 23 優化配置"
            ;;
            
        "mirage"|"assassin's creed mirage")
            export TU_DEBUG=noconform,perfc,flushall,forcebin
            export FD_DEV_FEATURES=enable_tp_ubwc_flag_hint=1,disable_prim_gmem_banding=1
            echo "已設置 Assassin's Creed Mirage 優化配置"
            ;;
            
        *)
            echo "使用默認優化配置"
            export TU_DEBUG=noconform,perfc,flushall
            ;;
    esac
}

# 使用方法: set_turnip_profile "遊戲名稱"
echo "遊戲配置腳本已加載"
EOF
    
    chmod 755 /data/local/tmp/turnip_config.sh
    chmod 755 /data/local/tmp/game_profiles.sh
    
    echo "優化配置創建完成"
}

# 創建 Magisk 模塊 (可選)
create_magisk_module() {
    if [ ! -d "/data/adb/modules" ]; then
        echo "Magisk 未找到，跳過模塊創建"
        return
    fi
    
    MODULE_DIR="/data/adb/modules/turnip_adreno_750"
    mkdir -p "$MODULE_DIR"
    
    cat > "$MODULE_DIR/module.prop" << EOF
id=turnip_adreno_750
name=Turnip Adreno 750 Optimized Driver
version=v1.0
versionCode=1
author=Adreno优化团队
description=优化版Turnip Vulkan驱动，专为Adreno 750和PC模拟器优化
EOF
    
    cat > "$MODULE_DIR/post-fs-data.sh" << 'EOF'
#!/system/bin/sh
# Magisk模块安装脚本

MODDIR=${0%/*}

# 复制驱动文件
if [ -f "$MODDIR/vulkan.adreno.so" ]; then
    if [ -d "/vendor/lib64/hw" ]; then
        cp "$MODDIR/vulkan.adreno.so" "/vendor/lib64/hw/vulkan.adreno.so"
        chmod 644 "/vendor/lib64/hw/vulkan.adreno.so"
        chown root:root "/vendor/lib64/hw/vulkan.adreno.so"
    fi
fi

# 设置环境变量
echo "export MESA_SHADER_CACHE_MAX_SIZE=2147483648" > /data/local/tmp/turnip_env.sh
echo "export TU_DEBUG=noconform,perfc" >> /data/local/tmp/turnip_env.sh
EOF
    
    cp "$WORKDIR/vulkan.adreno.so" "$MODULE_DIR/"
    chmod 755 "$MODULE_DIR/post-fs-data.sh"
    
    echo "Magisk 模塊創建完成: $MODULE_DIR"
}

# 驗證安裝
verify_installation() {
    echo "驗證安裝..."
    
    # 檢查驅動程式文件
    if [ -f "/vendor/lib64/hw/vulkan.adreno.so" ] || [ -f "/vendor/lib/hw/vulkan.adreno.so" ]; then
        echo "✓ 驅動程式文件已安裝"
        
        # 檢查驅動程式版本
        if command -v strings > /dev/null; then
            DRIVER_FILE=$(find /vendor -name "vulkan.adreno.so" -type f | head -1)
            if [ -n "$DRIVER_FILE" ]; then
                echo "驅動程式信息:"
                strings "$DRIVER_FILE" | grep -i "mesa\|turnip\|adreno" | head -5
            fi
        fi
    else
        echo "✗ 驅動程式文件未找到"
    fi
    
    # 檢查環境配置
    if [ -f "/data/local/tmp/turnip_config.sh" ]; then
        echo "✓ 優化配置已創建"
    fi
    
    echo ""
    echo "安裝驗證完成"
}

# 創建快速啟動腳本
create_quick_launch() {
    cat > /data/local/tmp/launch_turnip.sh << 'EOF'
#!/system/bin/sh
# 快速啟動 Turnip 優化環境

echo "加載 Turnip 優化配置..."
source /data/local/tmp/turnip_config.sh

# 根據參數加載遊戲特定配置
if [ $# -gt 0 ]; then
    source /data/local/tmp/game_profiles.sh
    set_turnip_profile "$1"
fi

# 顯示當前配置
echo "當前配置:"
echo "MESA_SHADER_CACHE_MAX_SIZE: $MESA_SHADER_CACHE_MAX_SIZE"
echo "TU_DEBUG: $TU_DEBUG"
echo "VK_ICD_FILENAMES: $VK_ICD_FILENAMES"

# 啟動 Vulkan 應用
echo "準備啟動 Vulkan 應用..."
EOF
    
    chmod 755 /data/local/tmp/launch_turnip.sh
    
    echo "快速啟動腳本創建完成"
    echo "使用方法: source /data/local/tmp/launch_turnip.sh [遊戲名稱]"
}

# 主安裝流程
main() {
    echo "開始安裝最佳 PC 模擬器驅動程式..."
    
    # 1. 備份現有驅動
    backup_existing_driver
    
    # 2. 下載最佳驅動程式
    download_best_driver
    
    # 3. 安裝驅動程式
    install_driver
    
    # 4. 創建優化配置
    create_optimized_config
    
    # 5. 創建 Magisk 模塊 (可選)
    create_magisk_module
    
    # 6. 創建快速啟動腳本
    create_quick_launch
    
    # 7. 驗證安裝
    verify_installation
    
    echo ""
    echo "========================================"
    echo "安裝完成！"
    echo "========================================"
    echo ""
    echo "重啟設備以使驅動程式生效"
    echo ""
    echo "使用說明:"
    echo "1. 重啟設備"
    echo "2. 在模擬器設置中，添加以下環境變量:"
    echo "   - MESA_SHADER_CACHE_MAX_SIZE=2147483648"
    echo "   - TU_DEBUG=noconform,perfc,flushall"
    echo "   - FD_DEV_FEATURES=enable_tp_ubwc_flag_hint=1"
    echo ""
    echo "或者使用快速啟動腳本:"
    echo "  source /data/local/tmp/launch_turnip.sh [遊戲名稱]"
    echo ""
    echo "遊戲名稱可選: horizon, valhalla, elden, spiderman, gow, tsushima, fifa, mirage"
    echo ""
    echo "備份文件保存在: $BACKUP_DIR"
    echo "如需恢復原驅動，請從備份目錄複製文件"
}

# 執行主安裝流程
main
EOF
chmod +x install-best-driver.sh

# Create README.md
cat > README.md << 'EOF'
# Mesa Turnip Driver for Android

This repository provides optimized Turnip Vulkan drivers for Adreno 750 on Android, tailored for PC emulators like Winlator. Includes installation scripts, configurations, and tools.

## Installation
1. Push install-best-driver.sh to device via adb.
2. Run with root: adb shell su -c "/data/local/tmp/install-best-driver.sh"
3. Reboot and configure in Winlator.

## Tools
- tools/uninstall.sh: Remove driver.
- tools/verify_vulkan.sh: Check Vulkan version.

## Configurations
- configs/vkd3d-proton.conf: For DX12 games.
- configs/dxvk.conf: For DX11 games.

## CI/CD
GitHub Actions workflow for automated builds.
EOF

# Create .gitignore
cat > .gitignore << 'EOF'
# Ignore temporary files
*.backup
*.tmp
*.log

# Ignore directories
turnip_install/
turnip_backup_*/
EOF

# Create tools/uninstall.sh
cat > tools/uninstall.sh << 'EOF'
#!/usr/bin/env bash
set -e

# Check root
if [ "$(whoami)" != "root" ]; then
    echo "Error: Requires root."
    exit 1
fi

# Restore backup if exists
INSTALL_PATH="/vendor/lib64/hw/vulkan.adreno.so"
if [ -f "${INSTALL_PATH}.backup" ]; then
    mv "${INSTALL_PATH}.backup" "$INSTALL_PATH"
    echo "Driver restored."
else
    echo "No backup found."
fi

# Remove configs
rm -f /data/local/tmp/turnip_config.sh /data/local/tmp/game_profiles.sh /data/local/tmp/launch_turnip.sh /data/local/tmp/turnip_env.sh

echo "Uninstall complete. Reboot device."
EOF
chmod +x tools/uninstall.sh

# Create tools/verify_vulkan.sh
cat > tools/verify_vulkan.sh << 'EOF'
#!/usr/bin/env bash
set -e

# Check Vulkan driver info
DRIVER_FILE=$(find /vendor -name "vulkan.adreno.so" -type f | head -1)
if [ -n "$DRIVER_FILE" ]; then
    strings "$DRIVER_FILE" | grep -i "mesa\|turnip\|vulkan" | head -5
else
    echo "Driver not found."
fi
EOF
chmod +x tools/verify_vulkan.sh

# Create configs/vkd3d-proton.conf
cat > configs/vkd3d-proton.conf << 'EOF'
# VKD3D-Proton config for DX12 optimization
vkd3d_config = no_upload_hvv,no_explicit_sync
EOF

# Create configs/dxvk.conf
cat > configs/dxvk.conf << 'EOF'
# DXVK config for DX11 games
dxvk.hud = fps
dxvk.enableAsync = true
EOF

# Create .github/workflows/build.yml
cat > .github/workflows/build.yml << 'EOF'
name: Build Validation

on: [push, pull_request]

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3
      - name: Check scripts
        run: |
          bash -n install-best-driver.sh
          bash -n tools/uninstall.sh
          bash -n tools/verify_vulkan.sh
EOF

# Commit and push to main
git add .
git commit -m "Add project structure, scripts, tools, configs, and CI workflow"
git push origin main
