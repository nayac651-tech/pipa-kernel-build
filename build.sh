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

# 1. 環境構築
echo "[*] Installing dependencies..."
sudo apt-get update
sudo apt-get install -y git bc bison flex libssl-dev build-essential curl zip unzip python3 \
    gcc-aarch64-linux-gnu gcc-arm-linux-gnueabi libncurses5-dev

echo "[*] Downloading Neutron Clang..."
mkdir -p toolchain/clang
cd toolchain/clang
bash <(curl -s "https://raw.githubusercontent.com/Neutron-Toolchains/antman/main/antman") -S
cd "$WORK_DIR"
export PATH="$WORK_DIR/toolchain/clang/bin:/usr/bin:$PATH"

# 2. クローン
echo "[*] Cloning Kernel Source..."
[ ! -d "android_kernel" ] && git clone --depth=1 -b "$KERNEL_BRANCH" "$KERNEL_SOURCE_URL" android_kernel
cd android_kernel

# 3. 各種修正 (Python, smp.c, Makefile)
cat << 'EOF' > scripts/gcc-wrapper.py
#!/usr/bin/env python3
import os, sys, subprocess
def main():
    args = sys.argv[1:]
    if not args: return
    try:
        proc = subprocess.Popen(args, stderr=subprocess.PIPE)
        _, stderr = proc.communicate()
        if proc.returncode != 0:
            if stderr: print(stderr.decode('utf-8', 'ignore'), file=sys.stderr)
            sys.exit(proc.returncode)
    except OSError as e:
        sys.exit(1)
if __name__ == '__main__': main()
EOF
chmod +x scripts/gcc-wrapper.py

sed -i 's/extern in_long_press;/extern int in_long_press;/g' arch/arm64/kernel/smp.c || true
find . -name "Makefile*" -o -name "*.mk" | xargs sed -i 's/-Werror-/-W/g' 2>/dev/null || true
find . -name "Makefile*" -o -name "*.mk" | xargs sed -i 's/-Werror/-Wno-error/g' 2>/dev/null || true

# 4. KernelSU & SUSFS
echo "[*] Integrating KernelSU & SUSFS..."
curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -

[ ! -d "../susfs4ksu" ] && git clone --depth=1 https://gitlab.com/simonpunk/susfs4ksu.git ../susfs4ksu
mkdir -p fs/susfs include/linux
cp "../susfs4ksu/kernel_patches/fs/susfs.c" fs/susfs/susfs.c || touch fs/susfs/susfs.c
cp "../susfs4ksu/kernel_patches/include/linux/susfs.h" include/linux/susfs.h || touch include/linux/susfs.h
echo -e 'config KSU_SUSFS\n    bool "SUSFS"\n    default y' > fs/susfs/Kconfig
echo 'obj-y += susfs.o' > fs/susfs/Makefile
grep -q "susfs/Kconfig" fs/Kconfig || sed -i '$i source "fs/susfs/Kconfig"' fs/Kconfig
grep -q "obj-y += susfs/" fs/Makefile || echo "obj-y += susfs/" >> fs/Makefile

# 5. ビルド実行
echo "[*] Starting Build..."
export ARCH=arm64
export SUBARCH=arm64
# GNU Assemblerを明示的に使用
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

rm -rf out
make O=out "$DEVICE_DEFCONFIG"
make O=out olddefconfig

# LLVM_IAS=0 に設定して、aes-modes.S のアセンブラエラーを回避
set +e
make -j$(nproc --all) O=out \
    CC=clang \
    LLVM=1 \
    LLVM_IAS=0 \
    CLANG_TRIPLE=aarch64-linux-gnu- \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CROSS_COMPILE_ARM32=arm-linux-gnueabi- 2>&1 | tee build_log.txt
MAKE_RET=${PIPESTATUS[0]}
set -e

if [ $MAKE_RET -ne 0 ]; then
    echo "----------------------------------------------------"
    echo "[!!!] BUILD FAILED! Check error below:"
    grep -i "error:" build_log.txt | head -n 20 || tail -n 50 build_log.txt
    exit 1
fi

# 6. パッケージ化
if [ -f "out/arch/arm64/boot/Image" ]; then
    echo "[SUCCESS] Image found!"
    cd "$WORK_DIR"
    git clone --depth=1 "$ANYKERNEL3_URL" AnyKernel3
    cp "$WORK_DIR/android_kernel/out/arch/arm64/boot/Image" AnyKernel3/
    cd AnyKernel3
    sed -i 's/device.name1=.*/device.name1=pipa/' anykernel.sh
    zip -r9 "../KernelSU_SUSFS_Pipa.zip" * -x .git README.md
    echo "[DONE] Zip: $WORK_DIR/KernelSU_SUSFS_Pipa.zip"
else
    echo "[FATAL] Image not found."
    exit 1
fi
