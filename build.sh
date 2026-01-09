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
# 1. 環境構築
# ==========================================
echo "[*] Installing dependencies..."
sudo apt-get update
sudo apt-get install -y git bc bison flex libssl-dev build-essential curl zip unzip python3

echo "[*] Downloading Toolchain (Neutron Clang)..."
mkdir -p toolchain/clang
cd toolchain/clang
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
# 3. Python 3 互換性パッチ (さらに強化)
# ==========================================
echo "[*] Patching scripts for Python 3 compatibility..."
# 複雑な print 文のパターンを網羅的に置換
find scripts/ -name "*.py" -exec sed -i 's/print "\(.*\)"/print("\1")/g' {} +
find scripts/ -name "*.py" -exec sed -i 's/print \(.*\),/print(\1, end=" ")/g' {} +
find scripts/ -name "*.py" -exec sed -i 's/print \(.*\)/print(\1)/g' {} +
# インタープリタ指定を python3 に強制書き換え
find scripts/ -name "*.py" -exec sed -i 's|#!/usr/bin/env python|#!/usr/bin/env python3|g' {} +
find scripts/ -name "*.py" -exec sed -i 's|#!/usr/bin/python|#!/usr/bin/python3|g' {} +

# ==========================================
# 4. KernelSU (KSU) の統合
# ==========================================
echo "[*] Integrating KernelSU..."
curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -

# ==========================================
# 5. SUSFS (Root隠蔽) の統合 (修正版)
# ==========================================
echo "[*] Integrating SUSFS..."
if [ ! -d "../susfs4ksu" ]; then
    git clone --depth=1 https://gitlab.com/simonpunk/susfs4ksu.git ../susfs4ksu
fi

SUSFS_PATCH_DIR="../susfs4ksu/kernel_patches"

mkdir -p fs/susfs
# ファイルを個別に、確実にコピー
cp "$SUSFS_PATCH_DIR/fs/susfs.c" fs/susfs/ || find "$SUSFS_PATCH_DIR" -name "susfs.c" -exec cp {} fs/susfs/ \; -quit
cp "$SUSFS_PATCH_DIR/include/linux/susfs.h" include/linux/ || find "$SUSFS_PATCH_DIR" -name "susfs.h" -exec cp {} include/linux/ \; -quit

# Kconfig と Makefile をバージョン 4.19 ディレクトリから優先的に取得
find "$SUSFS_PATCH_DIR" -path "*/4.19/*" -name "*Kconfig*" -exec cp {} fs/susfs/Kconfig \; -quit
find "$SUSFS_PATCH_DIR" -path "*/4.19/*" -name "*Makefile*" -exec cp {} fs/susfs/Makefile \; -quit

# 見つからなかった場合の最終フォールバック
[ ! -s fs/susfs/Kconfig ] && find "$SUSFS_PATCH_DIR" -name "*Kconfig*" -exec cp {} fs/susfs/Kconfig \; -quit
[ ! -s fs/susfs/Makefile ] && find "$SUSFS_PATCH_DIR" -name "*Makefile*" -exec cp {} fs/susfs/Makefile \; -quit

echo "[*] SUSFS Files Check:"
ls -l fs/susfs/

# 既存の fs/Kconfig へのパッチ適用
if ! grep -q "susfs" fs/Kconfig; then
    echo "[*] Patching fs/Kconfig..."
    # 最終行より前に source を挿入
    sed -i '$i source "fs/susfs/Kconfig"' fs/Kconfig
fi

# 既存の fs/Makefile へのパッチ適用
if ! grep -q "susfs" fs/Makefile; then
    echo "[*] Patching fs/Makefile..."
    echo "obj-\$(CONFIG_KSU_SUSFS) += susfs/" >> fs/Makefile
fi

# Defconfig への設定追加
echo "[*] Updating Defconfig ($DEVICE_DEFCONFIG)..."
CONFIG_PATH="arch/arm64/configs/$DEVICE_DEFCONFIG"
sed -i '/CONFIG_KSU/d' "$CONFIG_PATH"
sed -i '/CONFIG_KSU_SUSFS/d' "$CONFIG_PATH"
{
    echo "CONFIG_KSU=y"
    echo "CONFIG_KSU_SUSFS=y"
    echo "CONFIG_KSU_SUSFS_SUS_PATH=y"
    echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y"
} >> "$CONFIG_PATH"

# ==========================================
# 6. ビルド実行
# ==========================================
echo "[*] Starting Build..."
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
export CC=clang
export LD=ld.lld

# クリーンアップ
rm -rf out
make O=out "$DEVICE_DEFCONFIG"

# ビルド開始
make -j$(nproc --all) O=out \
    CC=clang \
    LLVM=1 \
    LLVM_IAS=1 \
    CLANG_TRIPLE=aarch64-linux-gnu-

# ==========================================
# 7. AnyKernel3 によるZip作成
# ==========================================
if [ -f "out/arch/arm64/boot/Image" ]; then
    echo "[SUCCESS] Kernel Image built successfully!"
    cd "$WORK_DIR"
    git clone --depth=1 "$ANYKERNEL3_URL" AnyKernel3
    cd AnyKernel3
    cp "$WORK_DIR/android_kernel/out/arch/arm64/boot/Image" .
    sed -i 's/device.name1=.*/device.name1=pipa/' anykernel.sh
    zip -r9 "../KernelSU_SUSFS_Pipa.zip" * -x .git README.md *placeholder
    echo "[DONE] Final Zip: $WORK_DIR/KernelSU_SUSFS_Pipa.zip"
else
    echo "[ERROR] Build failed."
    exit 1
fi
