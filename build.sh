#!/bin/bash
set -e

# ==========================================
# 設定エリア: Xiaomi Pad 6 (pipa) 用
# ==========================================
KERNEL_SOURCE_URL="https://github.com/MiCode/Xiaomi_Kernel_OpenSource"
KERNEL_BRANCH="pipa-t-oss"
DEVICE_DEFCONFIG="vendor/pipa_user_defconfig"
ANYKERNEL3_URL="https://github.com/osm0sis/AnyKernel3"

# 作業ディレクトリ設定
WORK_DIR=$(pwd)/kernel_workspace
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# ==========================================
# 1. 環境構築 & ツールチェーンの準備
# ==========================================
echo "[*] Installing dependencies..."
sudo apt-get update
sudo apt-get install -y git bc bison flex libssl-dev build-essential curl zip unzip

echo "[*] Downloading Toolchain (Neutron Clang)..."
# Xiaomiのカーネルは比較的新しいため、Neutron Clangを使用します
mkdir -p toolchain/clang
cd toolchain/clang
# 最新のNeutron Clangを取得する簡易スクリプト（またはお好みのClang URLに変更可）
bash <(curl -s "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman") -S
cd "$WORK_DIR"

export PATH="$WORK_DIR/toolchain/clang/bin:$PATH"

# ==========================================
# 2. カーネルソースのクローン
# ==========================================
echo "[*] Cloning Kernel Source ($KERNEL_BRANCH)..."
if [ ! -d "android_kernel" ]; then
    git clone --depth=1 -b "$KERNEL_BRANCH" "$KERNEL_SOURCE_URL" android_kernel
fi
cd android_kernel

# ==========================================
# 3. KernelSU (KSU) の統合
# ==========================================
echo "[*] Integrating KernelSU..."
curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -

# ==========================================
# 4. SUSFS (Root隠蔽) の統合
# ==========================================
echo "[*] Integrating SUSFS..."
# SUSFSリポジトリのクローン
if [ ! -d "../susfs4ksu" ]; then
    git clone --depth=1 https://gitlab.com/simonpunk/susfs4ksu.git ../susfs4ksu
fi

# カーネルバージョン(4.19)に合わせてコピー
# 注意: SUSFSの構造は変更されることがあるため、パスは汎用的にfs/にコピーします
cp ../susfs4ksu/kernel_patches/fs/* fs/ -r
cp ../susfs4ksu/kernel_patches/include/linux/* include/linux/ -r

# fs/Kconfig へのパッチ適用 (SUSFS設定を追加)
if ! grep -q "susfs" fs/Kconfig; then
    echo "[*] Patching fs/Kconfig..."
    # "endmenu" の直前に source "fs/susfs/Kconfig" を挿入
    sed -i "/endmenu/i source \"fs/susfs/Kconfig\"" fs/Kconfig
fi

# fs/Makefile へのパッチ適用
if ! grep -q "susfs" fs/Makefile; then
    echo "[*] Patching fs/Makefile..."
    echo "obj-\$(CONFIG_KSU_SUSFS) += susfs/" >> fs/Makefile
fi

# Defconfig への設定追加 (KernelSU & SUSFS有効化)
echo "[*] Updating Defconfig ($DEVICE_DEFCONFIG)..."
CONFIG_PATH="arch/arm64/configs/$DEVICE_DEFCONFIG"

# KernelSU設定
echo "CONFIG_KSU=y" >> "$CONFIG_PATH"

# SUSFS設定
echo "CONFIG_KSU_SUSFS=y" >> "$CONFIG_PATH"
echo "CONFIG_KSU_SUSFS_SUS_PATH=y" >> "$CONFIG_PATH"
# SUSFS_SUS_MOUNTなどは必要に応じて追加

# ==========================================
# 5. ビルド実行
# ==========================================
echo "[*] Starting Build..."
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
export CC=clang
export LD=ld.lld
export AS=llvm-as
export AR=llvm-ar
export NM=llvm-nm
export OBJCOPY=llvm-objcopy
export OBJDUMP=llvm-objdump

# defconfig適用
make O=out "$DEVICE_DEFCONFIG"

# ビルド開始
make -j$(nproc --all) O=out \
    CC=clang \
    LLVM=1 \
    LLVM_IAS=1

# ==========================================
# 6. AnyKernel3 によるZip作成
# ==========================================
if [ -f "out/arch/arm64/boot/Image" ]; then
    echo "[SUCCESS] Kernel Image built successfully!"
    
    echo "[*] Packaging with AnyKernel3..."
    cd "$WORK_DIR"
    git clone --depth=1 "$ANYKERNEL3_URL" AnyKernel3
    cd AnyKernel3
    
    # ビルドしたImageをコピー
    cp "$WORK_DIR/android_kernel/out/arch/arm64/boot/Image" .
    # dtb/dtboが必要な場合はここに追加コピー処理が必要ですが、
    # 基本的なGKI/Non-GKI構成ならImageのみで起動テスト可能です。
    # 必要に応じて dtb もコピーしてください:
    # find "$WORK_DIR/android_kernel/out/arch/arm64/boot/dts/vendor/qcom/" -name "*.dtb" -exec cp {} dtb \;

    # AnyKernel3の設定を簡易的に書き換え (デバイス名など)
    sed -i 's/device.name1=.*/device.name1=pipa/' anykernel.sh
    
    # Zip化
    zip -r9 "../KernelSU_SUSFS_Pipa.zip" * -x .git README.md *placeholder
    
    echo "[DONE] Final Zip: $WORK_DIR/KernelSU_SUSFS_Pipa.zip"
else
    echo "[ERROR] Build failed. Image not found."
    exit 1
fi
