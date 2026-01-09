#!/bin/bash
set -e

# ==========================================
# 設定エリア: Xiaomi Pad 6 (pipa) 用
# ==========================================
KERNEL_SOURCE_URL="https://github.com/MiCode/Xiaomi_Kernel_OpenSource"
KERNEL_BRANCH="pipa-t-oss"
DEVICE_DEFCONFIG="vendor/pipa_user_defconfig"
ANYKERNEL3_URL="https://github.com/osm0sis/AnyKernel3"

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
echo "[*] Cloning Kernel Source..."
if [ ! -d "android_kernel" ]; then
    git clone --depth=1 -b "$KERNEL_BRANCH" "$KERNEL_SOURCE_URL" android_kernel
fi
cd android_kernel

# ==========================================
# 3. Python 3 互換性修正 (安全版)
# ==========================================
echo "[*] Patching scripts for Python 3..."
# 全ての .py ファイルに対して、print 文の後ろを壊さないように正規表現で修正
find scripts/ -name "*.py" -exec sed -i 's/print "\(.*\)"/print("\1")/g' {} +
find scripts/ -name "*.py" -exec sed -i 's/print \(.*\),/print(\1, end=" ")/g' {} +
# 特定の gcc-wrapper.py のエラー箇所を直接修正
sed -i 's/print args\[0\] + ":", e.strerror/print(args[0] + ":", e.strerror)/g' scripts/gcc-wrapper.py

# ==========================================
# 4. KernelSU (KSU) の統合
# ==========================================
echo "[*] Integrating KernelSU..."
curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -

# ==========================================
# 5. SUSFS (Root隠蔽) の統合
# ==========================================
echo "[*] Integrating SUSFS..."
if [ ! -d "../susfs4ksu" ]; then
    git clone --depth=1 https://gitlab.com/simonpunk/susfs4ksu.git ../susfs4ksu
fi

SUSFS_PATCH_DIR="../susfs4ksu/kernel_patches"
mkdir -p fs/susfs

# 4.19用のファイルを特定してコピー
echo "[*] Copying SUSFS files..."
cp "$SUSFS_PATCH_DIR/fs/susfs.c" fs/susfs/ || find "$SUSFS_PATCH_DIR" -name "susfs.c" -exec cp {} fs/susfs/ \; -quit
cp "$SUSFS_PATCH_DIR/include/linux/susfs.h" include/linux/ || find "$SUSFS_PATCH_DIR" -name "susfs.h" -exec cp {} include/linux/ \; -quit

# Kconfig / Makefile の配置 (4.19 ディレクトリ配下を最優先)
find "$SUSFS_PATCH_DIR" -path "*/4.19/*" -name "Kconfig*" -exec cp {} fs/susfs/Kconfig \; -quit
find "$SUSFS_PATCH_DIR" -path "*/4.19/*" -name "Makefile*" -exec cp {} fs/susfs/Makefile \; -quit

# それでも無い場合の最終チェック
if [ ! -s fs/susfs/Kconfig ]; then
    find "$SUSFS_PATCH_DIR" -name "Kconfig_susfs" -exec cp {} fs/susfs/Kconfig \; -quit
fi
if [ ! -s fs/susfs/Makefile ]; then
    find "$SUSFS_PATCH_DIR" -name "Makefile_susfs" -exec cp {} fs/susfs/Makefile \; -quit
fi

echo "[*] SUSFS files status:"
ls -l fs/susfs/
ls -l include/linux/susfs.h

# パッチ適用
if ! grep -q "susfs" fs/Kconfig; then
    sed -i '$i source "fs/susfs/Kconfig"' fs/Kconfig
fi
if ! grep -q "susfs" fs/Makefile; then
    echo "obj-\$(CONFIG_KSU_SUSFS) += susfs/" >> fs/Makefile
fi

# Defconfig更新
CONFIG_PATH="arch/arm64/configs/$DEVICE_DEFCONFIG"
# KSU/SUSFS関連の設定を一度消して、最新を追記
sed -i '/CONFIG_KSU/d' "$CONFIG_PATH"
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
export CC=clang
export LD=ld.lld

# クリーンビルド
rm -rf out
make O=out "$DEVICE_DEFCONFIG"

# コンパイル開始 (LLVM=1で統合ツールチェーンを使用)
make -j$(nproc --all) O=out \
    CC=clang \
    LLVM=1 \
    LLVM_IAS=1 \
    CLANG_TRIPLE=aarch64-linux-gnu- \
    CROSS_COMPILE=aarch64-linux-gnu-

# ==========================================
# 7. 成果物パッケージ化
# ==========================================
if [ -f "out/arch/arm64/boot/Image" ]; then
    echo "[SUCCESS] Kernel Built!"
    cd "$WORK_DIR"
    git clone --depth=1 "$ANYKERNEL3_URL" AnyKernel3
    cd AnyKernel3
    cp "$WORK_DIR/android_kernel/out/arch/arm64/boot/Image" .
    # dtbファイル等がある場合はここで追加
    find "$WORK_DIR/android_kernel/out/arch/arm64/boot/dts/vendor/qcom/" -name "*.dtb" -exec cp {} . \; 2>/dev/null || true
    
    sed -i 's/device.name1=.*/device.name1=pipa/' anykernel.sh
    zip -r9 "../KernelSU_SUSFS_Pipa.zip" * -x .git README.md
    echo "[DONE] Zip: $WORK_DIR/KernelSU_SUSFS_Pipa.zip"
else
    echo "[ERROR] Build failed. Image not found."
    exit 1
fi
