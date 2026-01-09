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
# 1. 環境構築 (コンパイラの追加)
# ==========================================
echo "[*] Installing dependencies..."
sudo apt-get update
sudo apt-get install -y git bc bison flex libssl-dev build-essential curl zip unzip python3 \
    gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi libncurses5-dev

echo "[*] Downloading Neutron Clang..."
mkdir -p toolchain/clang
cd toolchain/clang
bash <(curl -s "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman") -S
cd "$WORK_DIR"

# パス設定: Clang と システムの GCC 両方を使えるようにする
export PATH="$WORK_DIR/toolchain/clang/bin:/usr/bin:$PATH"

# ==========================================
# 2. カーネルソースのクローン
# ==========================================
echo "[*] Cloning Kernel Source..."
if [ ! -d "android_kernel" ]; then
    git clone --depth=1 -b "$KERNEL_BRANCH" "$KERNEL_SOURCE_URL" android_kernel
fi
cd android_kernel

# ==========================================
# 3. Python 3 互換性修正 (前回成功した方法)
# ==========================================
echo "[*] Overwriting gcc-wrapper.py with Python 3 version..."
cat << 'EOF' > scripts/gcc-wrapper.py
#!/usr/bin/env python3
import os
import sys
import subprocess

def main():
    args = sys.argv[1:]
    if not args:
        return
    try:
        proc = subprocess.Popen(args, stderr=subprocess.PIPE)
        _, stderr = proc.communicate()
        if proc.returncode != 0:
            if stderr:
                print(stderr.decode('utf-8', 'ignore'), file=sys.stderr)
            sys.exit(proc.returncode)
    except OSError as e:
        # コンパイラが見つからないエラーを詳細に出力
        print(f"Error executing {args[0]}: {e.strerror}", file=sys.stderr)
        sys.exit(1)

if __name__ == '__main__':
    main()
EOF
chmod +x scripts/gcc-wrapper.py

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

cp "$SUSFS_PATCH_DIR/fs/susfs.c" fs/susfs/ || find "$SUSFS_PATCH_DIR" -name "susfs.c" -exec cp {} fs/susfs/ \;
cp "$SUSFS_PATCH_DIR/include/linux/susfs.h" include/linux/ || find "$SUSFS_PATCH_DIR" -name "susfs.h" -exec cp {} include/linux/ \;

# Kconfig / Makefile のダミー生成を回避し、できるだけ検索
find "$SUSFS_PATCH_DIR" -name "*Kconfig*" | grep "4.19" | xargs -I {} cp {} fs/susfs/Kconfig || echo 'config KSU_SUSFS' > fs/susfs/Kconfig
find "$SUSFS_PATCH_DIR" -name "*Makefile*" | grep "4.19" | xargs -I {} cp {} fs/susfs/Makefile || echo 'obj-$(CONFIG_KSU_SUSFS) += susfs.o' > fs/susfs/Makefile

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

# 明示的にパスを指定
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

rm -rf out
make O=out "$DEVICE_DEFCONFIG"

# ビルド開始
# LLVM=1 を使用しつつ、GCCの補助も有効にする設定
make -j$(nproc --all) O=out \
    CC=clang \
    LLVM=1 \
    LLVM_IAS=1 \
    CLANG_TRIPLE=aarch64-linux-gnu- \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CROSS_COMPILE_ARM32=arm-linux-gnueabi-

# ==========================================
# 7. 成果物パッケージ化
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
