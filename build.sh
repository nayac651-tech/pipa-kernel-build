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

echo "[*] Downloading Toolchain..."
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
# 3. Python 3 互換性修正 (安全な個別修正)
# ==========================================
echo "[*] Fixing gcc-wrapper.py for Python 3..."
# エラーが出ていた gcc-wrapper.py を Python 3 向けに安全に置換
# 破壊的な一括置換はせず、特定のパターンのみを修正します
sed -i 's/print "error, forbidden warning:", m.group(2)/print("error, forbidden warning:", m.group(2))/g' scripts/gcc-wrapper.py
sed -i 's/print line,/print(line, end=" ")/g' scripts/gcc-wrapper.py
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

# ファイルをワイルドカードを使わずに個別にコピー
# 4.19用のフォルダがあるか確認しつつコピー
cp "$SUSFS_PATCH_DIR/fs/susfs.c" fs/susfs/ || true
cp "$SUSFS_PATCH_DIR/include/linux/susfs.h" include/linux/ || true

# Kconfig と Makefile を確実に配置
find "$SUSFS_PATCH_DIR" -name "*Kconfig*" | grep "4.19" | xargs -I {} cp {} fs/susfs/Kconfig || \
find "$SUSFS_PATCH_DIR" -name "*Kconfig*" | head -n 1 | xargs -I {} cp {} fs/susfs/Kconfig

find "$SUSFS_PATCH_DIR" -name "*Makefile*" | grep "4.19" | xargs -I {} cp {} fs/susfs/Makefile || \
find "$SUSFS_PATCH_DIR" -name "*Makefile*" | head -n 1 | xargs -I {} cp {} fs/susfs/Makefile

# チェック
echo "[*] SUSFS files status:"
ls -l fs/susfs/

if [ ! -f fs/susfs/Kconfig ]; then
    echo "ERROR: SUSFS Kconfig not found!"
    exit 1
fi

# パッチ適用
if ! grep -q "susfs" fs/Kconfig; then
    sed -i '$i source "fs/susfs/Kconfig"' fs/Kconfig
fi
if ! grep -q "susfs" fs/Makefile; then
    echo "obj-\$(CONFIG_KSU_SUSFS) += susfs/" >> fs/Makefile
fi

# Defconfig更新
CONFIG_PATH="arch/arm64/configs/$DEVICE_DEFCONFIG"
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

rm -rf out
make O=out "$DEVICE_DEFCONFIG"
make -j$(nproc --all) O=out CC=clang LLVM=1 LLVM_IAS=1 CLANG_TRIPLE=aarch64-linux-gnu-

# ==========================================
# 7. 成果物確認 & パッケージ化
# ==========================================
if [ -f "out/arch/arm64/boot/Image" ]; then
    echo "[SUCCESS] Kernel Built!"
    cd "$WORK_DIR"
    git clone --depth=1 "$ANYKERNEL3_URL" AnyKernel3
    cd AnyKernel3
    cp "$WORK_DIR/android_kernel/out/arch/arm64/boot/Image" .
    sed -i 's/device.name1=.*/device.name1=pipa/' anykernel.sh
    zip -r9 "../KernelSU_SUSFS_Pipa.zip" * -x .git README.md
else
    echo "[ERROR] Build failed."
    exit 1
fi
