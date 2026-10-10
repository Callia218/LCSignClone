#!/usr/bin/env bash
# 把 zsign 交叉编译成 iOS 静态库 libzsign.a
#
# 职责边界：只做「编译 + 归档」。
# OpenSSL 的**链接**交给 Xcode（通过 SwiftPM 引入 krzyzanowskim/OpenSSL），
# 编译阶段只需要 OpenSSL 的头文件 —— 头文件在 macOS 与 iOS 上是同一份，
# 所以这里直接复用 Homebrew 的 openssl@3，不必为头文件单独准备 iOS 版本。
#
# 用法：
#   ./Scripts/10_build_zsign.sh
#   ARCHS="arm64" IOS_MIN=15.0 ZSIGN_REF=master ./Scripts/10_build_zsign.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="$ROOT/Vendor"
BUILD="$ROOT/.build"
ZSIGN_SRC="$BUILD/zsign-src"
ZSIGN_OUT="$VENDOR/zsign"

ARCHS="${ARCHS:-arm64}"
IOS_MIN="${IOS_MIN:-15.0}"
ZSIGN_REF="${ZSIGN_REF:-master}"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
info() { printf '  %s\n' "$1"; }
die()  { printf '\033[31m错误: %s\033[0m\n' "$1" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "只能在 macOS 上构建（当前：$(uname -s)）"

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null)" \
  || die "找不到 iOS SDK，请安装 Xcode 并执行 xcode-select --install"

mkdir -p "$BUILD" "$VENDOR" "$ZSIGN_OUT/lib" "$ZSIGN_OUT/include"

# ---------------------------------------------------------------------------
# 1. OpenSSL 头文件
# ---------------------------------------------------------------------------
bold "[1/3] 定位 OpenSSL 头文件"

OPENSSL_INC=""
for candidate in \
    "$VENDOR/openssl/include" \
    "$(brew --prefix openssl@3 2>/dev/null)/include" \
    "$(brew --prefix openssl 2>/dev/null)/include" \
    "/usr/local/opt/openssl@3/include" \
    "/opt/homebrew/opt/openssl@3/include"
do
  if [[ -n "$candidate" && -f "$candidate/openssl/opensslv.h" ]]; then
    OPENSSL_INC="$candidate"
    break
  fi
done

if [[ -z "$OPENSSL_INC" ]]; then
  cat <<'EOF'
  找不到 OpenSSL 头文件。解决办法（任选其一）：

    macOS 本地：  brew install openssl@3
    CI 环境：     brew install openssl@3 后重试

  本项目通过 SwiftPM 引入 krzyzanowskim/OpenSSL 来链接，
  但编译 zsign 时仍需要一个可用的 openssl/ 头文件目录。
EOF
  die "OpenSSL 头文件未就绪"
fi
info "使用 $OPENSSL_INC"

# ---------------------------------------------------------------------------
# 2. 获取 zsign 源码
# ---------------------------------------------------------------------------
bold "[2/3] 获取 zsign 源码"
if [[ -d "$ZSIGN_SRC/.git" ]]; then
  info "已存在，更新到 $ZSIGN_REF"
  git -C "$ZSIGN_SRC" fetch --depth 1 origin "$ZSIGN_REF" >/dev/null 2>&1 || true
  git -C "$ZSIGN_SRC" checkout -q FETCH_HEAD 2>/dev/null || true
else
  git clone --depth 1 --branch "$ZSIGN_REF" \
      https://github.com/zhlynn/zsign.git "$ZSIGN_SRC" \
    || die "clone zsign 失败，检查网络，或改用 ZSIGN_REF=main"
  info "已克隆到 $ZSIGN_SRC"
fi

# ---------------------------------------------------------------------------
# 3. 交叉编译
# ---------------------------------------------------------------------------
bold "[3/3] 编译 libzsign.a（$ARCHS / iOS $IOS_MIN）"

INCLUDES=("-I$OPENSSL_INC")
while IFS= read -r dir; do INCLUDES+=("-I$dir"); done < <(
  find "$ZSIGN_SRC" -type f \( -name '*.h' -o -name '*.hpp' \) \
    -exec dirname {} \; | sort -u
)

SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(
  find "$ZSIGN_SRC" -type f \( -name '*.cpp' -o -name '*.cc' -o -name '*.c' \) \
    ! -path '*/test/*' ! -path '*/.git/*' | sort
)
[[ ${#SOURCES[@]} -gt 0 ]] || die "zsign 源码里找不到任何源文件，仓库结构可能变了"

OBJ_DIR="$BUILD/obj-zsign"
rm -rf "$OBJ_DIR" && mkdir -p "$OBJ_DIR"

index=0
for src in "${SOURCES[@]}"; do
  index=$((index + 1))
  printf '\r  编译 %d/%d  %s\033[K' "$index" "${#SOURCES[@]}" "$(basename "$src")"

  xcrun --sdk iphoneos clang++ -c "$src" \
    -arch "$ARCHS" \
    -isysroot "$SDK_PATH" \
    -miphoneos-version-min="$IOS_MIN" \
    -std=c++17 -O2 -fPIC \
    -fexceptions -frtti -DNDEBUG \
    "${INCLUDES[@]}" \
    -o "$OBJ_DIR/$(basename "$src").o" \
    || die "编译失败：$src"
done
printf '\r\033[K'

libtool -static -o "$ZSIGN_OUT/lib/libzsign.a" "$OBJ_DIR"/*.o 2>/dev/null \
  || ar rcs "$ZSIGN_OUT/lib/libzsign.a" "$OBJ_DIR"/*.o

while IFS= read -r header; do
  cp "$header" "$ZSIGN_OUT/include/"
done < <(find "$ZSIGN_SRC" -maxdepth 2 -type f -name 'zsign*.h')

[[ -f "$ZSIGN_OUT/lib/libzsign.a" ]] || die "libzsign.a 生成失败"
[[ -f "$ZSIGN_OUT/include/zsign.h" ]] || die "zsign.h 未导出"

echo
bold "完成"
echo "  Vendor/zsign/lib/libzsign.a   ($(du -h "$ZSIGN_OUT/lib/libzsign.a" | cut -f1), $ARCHS)"
echo "  Vendor/zsign/include/zsign.h"
echo
echo "下一步："
echo "  1. 核对 Vendor/zsign/include/zsign.h 里 Init / SignFolder 的参数顺序，"
echo "     与 Sources/LCSignCore/ZSign/ZSignBridge.mm 不一致就同步改掉"
echo "  2. xcodegen generate"
echo "  3. xcodebuild 构建"
echo
