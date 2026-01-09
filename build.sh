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
# 3. Python 3 互換性パッチ
# ==========================================
echo "[*] Patching scripts for Python 3 compatibility..."
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

# 4.19用のパッチディレクトリを指定
SUSFS_PATCH_DIR="../susfs4ksu/kernel_patches"

mkdir -p fs/susfs
# 必要なファイルをコピー (4.19系を明示的に指定)
cp "$SUSFS_PATCH_DIR/fs/susfs.c" fs/susfs/
cp "$SUSFS_PATCH_DIR/include/linux/susfs.h" include/linux/
cp "$SUSFS_PATCH_DIR/fs/Kconfig_susfs" fs/susfs/Kconfig
cp "$SUSFS_PATCH_DIR/fs/Makefile_susfs" fs/susfs/Makefile

# 既存の fs/Kconfig へのパッチ適用
if ! grep -q "susfs" fs/Kconfig; then
    echo "[*] Patching fs/Kconfig..."
    # 最後の endmenu の前に source を追加
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
echo "CONFIG_KSU=y" >> "$CONFIG_PATH"
echo "CONFIG_KSU_SUSFS=y" >> "$CONFIG_PATH"
echo "CONFIG_KSU_SUSFS_SUS_PATH=y" >> "$CONFIG_PATH"
echo "CONFIG_KSU_SUSFS_SUS_MOUNT=y" >> "$CONFIG_PATH"

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
    echo "[ERROR] Build failed. Check the logs above."
    exit 1
fi
