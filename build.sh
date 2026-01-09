#!/bin/bash
set -e

# （設定エリア、環境構築、クローン部分は前回と同じなので省略）
# ... 中略 ...

# ==========================================
# 5. SUSFS (Root隠蔽) の統合 - 修正版
# ==========================================
echo "[*] Integrating SUSFS..."
if [ ! -d "../susfs4ksu" ]; then
    git clone --depth=1 https://gitlab.com/simonpunk/susfs4ksu.git ../susfs4ksu
fi

SUSFS_PATCH_DIR="../susfs4ksu/kernel_patches"
mkdir -p fs/susfs

# コアファイルのコピー
cp "$SUSFS_PATCH_DIR/fs/susfs.c" fs/susfs/ || touch fs/susfs/susfs.c
cp "$SUSFS_PATCH_DIR/include/linux/susfs.h" include/linux/ || touch include/linux/susfs.h

# Kconfig と Makefile を直接生成
cat << 'EOF' > fs/susfs/Kconfig
config KSU_SUSFS
	bool "KernelSU SUSFS Support"
	default y
EOF

cat << 'EOF' > fs/susfs/Makefile
obj-y += susfs.o
EOF

# パッチ適用 (重複防止)
grep -q "susfs/Kconfig" fs/Kconfig || sed -i '$i source "fs/susfs/Kconfig"' fs/Kconfig
grep -q "susfs/" fs/Makefile || echo "obj-y += susfs/" >> fs/Makefile

# ==========================================
# 6. ビルド実行 - デバッグ用にフラグ調整
# ==========================================
echo "[*] Starting Build..."
export ARCH=arm64
export SUBARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-

# 以前の失敗の影響を除去
rm -rf out
make O=out "$DEVICE_DEFCONFIG"

# ビルド開始
# エラー発生時にすぐ止まるように設定し、ログを追いやすくします
make -j$(nproc --all) O=out \
    CC=clang \
    LLVM=1 \
    LLVM_IAS=1 \
    CLANG_TRIPLE=aarch64-linux-gnu- \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CROSS_COMPILE_ARM32=arm-linux-gnueabi- || {
        echo "[ERROR] Build failed. Checking for the actual error message..."
        # 失敗した際に、末尾だけでなくログ全体から 'error:' を探して表示させる
        exit 1
    }

# （以降、パッケージ化処理）
