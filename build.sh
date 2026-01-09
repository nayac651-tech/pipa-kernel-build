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
# python2 を除外し、python3-ミニマムな構成に変更
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
# 3. Python 2 構文エラーの自動修正 (重要)
# ==========================================
echo "[*] Patching scripts for Python 3 compatibility..."
# エラーの原因だった print 文を Python 3 形式に一括置換
find scripts/ -name "*.py" -exec sed -i 's/print "\(.*\)"/print("\1")/g' {} +
find scripts/ -name "*.py" -exec sed -i 's/print "error, forbidden warning:", m.group(2)/print("error, forbidden warning:", m.group(2))/g' {} +

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

mkdir -p fs/susfs
cp ../susfs4ksu/kernel_patches/fs/susfs.c fs/susfs/
cp ../susfs4ksu/kernel_patches/include/linux/susfs.h include/linux/
cp ../susfs4ksu/kernel_patches/fs/Kconfig fs/susfs/
cp ../susfs4ksu/kernel_patches/fs/Makefile fs/susfs/

if ! grep -q "susfs" fs/Kconfig; then
    echo "[*] Patching fs/Kconfig..."
    # 最後の endmenu の前に挿入
    sed -i '$i source "fs/susfs/Kconfig"' fs/Kconfig
fi

if ! grep -q "susfs" fs/Makefile; then
    echo "[*] Patching fs/Makefile..."
    echo "obj-\$(CONFIG_KSU_SUSFS) += susfs/" >> fs/Makefile
fi

# Defconfig への設定追加
echo "[*] Updating Defconfig ($DEVICE_DEFCONFIG)..."
CONFIG_PATH="arch/arm64/configs/$DEVICE_DEFCONFIG"
# 既存の設定をクリーンアップ
sed -i '/CONFIG_KSU/d' "$CONFIG_PATH"
sed -i '/CONFIG_KSU_SUSFS/d' "$CONFIG_PATH"
# 新規追加
echo "CONFIG_KSU=y" >> "$CONFIG_PATH"
echo "CONFIG_KSU_SUSFS=y" >> "$CONFIG_PATH"
echo "CONFIG_KSU_SUSFS_SUS_PATH=y" >> "$CONFIG_PATH"

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

# defconfig適用
make O=out "$DEVICE_DEFCONFIG"

# ビルド開始
make -j$(nproc --all) O=out \
    CC=clang \
    LLVM=1 \
    LLVM_IAS=1

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
