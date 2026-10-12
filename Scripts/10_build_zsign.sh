#!/usr/bin/env bash
# 把 zsign 交叉编译成 iOS 静态库
#
# 职责边界：只做「编译 + 归档」。
# OpenSSL 的**链接**交给 Xcode（通过 SwiftPM 引入 krzyzanowski/OpenSSL），
# 编译阶段只需要 OpenSSL 的头文件 —— 头文件在 macOS 与 iOS 上是同一份，
# 所以这里直接复用 Homebrew 的 openssl@3。
#
# 产出（按平台分目录，Xcode 侧用 $(PLATFORM_NAME) 取对应那份）：
#   Vendor/zsign/lib/iphoneos/libzsign.a
#   Vendor/zsign/lib/iphonesimulator/libzsign.a
#   Vendor/zsign/include/zsign_shim.h     桥接层唯一需要 include 的头文件
#
# 为什么要连模拟器切片一起编：
#   1. 单元测试跑在模拟器上，链接不到 device-only 的静态库会直接失败
#      （building for iOS Simulator, but linking in object file built for iOS）；
#   2. 平时调 UI 用模拟器比真机快得多，没有这个切片就只能上真机。
#
# 用法：
#   bash Scripts/10_build_zsign.sh
#   PLATFORMS="iphoneos" IOS_MIN=15.0 ZSIGN_REF=master bash Scripts/10_build_zsign.sh
#
# 注意：本脚本内所有变量引用一律写成 ${VAR} 形式。
# 全角字符（如「）」）紧跟 $VAR 时，bash 在部分 locale 下会把多字节字符的
# 首字节吞进变量名，导致 "unbound variable" —— CI 上就是这么炸的。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR="${ROOT}/Vendor"
BUILD="${ROOT}/.build"
ZSIGN_SRC="${BUILD}/zsign-src"
ZSIGN_OUT="${VENDOR}/zsign"
SHIM_DIR="${ROOT}/Scripts/zsign_shim"

# 默认两个平台都编。只想出真机包时传 PLATFORMS=iphoneos 省一半时间。
PLATFORMS="${PLATFORMS:-iphoneos iphonesimulator}"
IOS_MIN="${IOS_MIN:-15.0}"
ZSIGN_REF="${ZSIGN_REF:-master}"

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
info() { printf '  %s\n' "$1"; }
die()  { printf '\033[31m错误: %s\033[0m\n' "$1" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || die "只能在 macOS 上构建（当前 $(uname -s)）"

# 某个平台要编哪些架构
archs_for() {
  case "$1" in
    iphoneos)        echo "arm64" ;;
    iphonesimulator) echo "arm64 x86_64" ;;
    *)               echo "arm64" ;;
  esac
}

# 某个平台的最低版本参数。SDK 不同，clang 认的旗标也不同 ——
# 给模拟器传 -miphoneos-version-min 是会被忽略的。
min_flag_for() {
  case "$1" in
    iphoneos)        echo "-miphoneos-version-min=${IOS_MIN}" ;;
    iphonesimulator) echo "-mios-simulator-version-min=${IOS_MIN}" ;;
    *)               echo "-miphoneos-version-min=${IOS_MIN}" ;;
  esac
}

mkdir -p "${BUILD}" "${VENDOR}" "${ZSIGN_OUT}/lib" "${ZSIGN_OUT}/include"

# ---------------------------------------------------------------------------
# 1. OpenSSL 头文件
# ---------------------------------------------------------------------------
bold "[1/5] 定位 OpenSSL 头文件"

OPENSSL_INC=""
for candidate in \
    "${VENDOR}/openssl/include" \
    "$(brew --prefix openssl@3 2>/dev/null)/include" \
    "$(brew --prefix openssl 2>/dev/null)/include" \
    "/opt/homebrew/opt/openssl@3/include" \
    "/usr/local/opt/openssl@3/include"
do
  if [[ -n "${candidate}" && -f "${candidate}/openssl/opensslv.h" ]]; then
    OPENSSL_INC="${candidate}"
    break
  fi
done

if [[ -z "${OPENSSL_INC}" ]]; then
  cat <<'EOF'
  找不到 OpenSSL 头文件。解决办法（任选其一）：

    本地：  brew install openssl@3
    CI：    在 workflow 里加 brew install openssl@3

  链接用的 OpenSSL 由 SwiftPM 的 krzyzanowskim/OpenSSL 提供，
  但编译 zsign 时仍需要一个可用的 openssl/ 头文件目录。
EOF
  die "OpenSSL 头文件未就绪"
fi
info "使用 ${OPENSSL_INC}"

# ---------------------------------------------------------------------------
# 2. 获取 zsign 源码
# ---------------------------------------------------------------------------
bold "[2/5] 获取 zsign 源码"
if [[ -d "${ZSIGN_SRC}/.git" ]]; then
  info "已存在，更新到 ${ZSIGN_REF}"
  git -C "${ZSIGN_SRC}" fetch --depth 1 origin "${ZSIGN_REF}" >/dev/null 2>&1 || true
  git -C "${ZSIGN_SRC}" checkout -q FETCH_HEAD 2>/dev/null || true
else
  git clone --depth 1 --branch "${ZSIGN_REF}" \
      https://github.com/zhlynn/zsign.git "${ZSIGN_SRC}" \
    || die "clone zsign 失败，检查网络，或改用 ZSIGN_REF=main"
  info "已克隆到 ${ZSIGN_SRC}"
fi

# ---------------------------------------------------------------------------
# 3. 收集编译参数
# ---------------------------------------------------------------------------
bold "[3/5] 收集源文件"

INCLUDES=("-I${OPENSSL_INC}")
while IFS= read -r dir; do
  INCLUDES+=("-I${dir}")
done < <(
  find "${ZSIGN_SRC}" -type f \( -name '*.h' -o -name '*.hpp' \) \
    ! -path '*/build/*' -exec dirname {} \; | sort -u
)

SOURCES=()
while IFS= read -r file; do
  SOURCES+=("${file}")
done < <(
  find "${ZSIGN_SRC}" -type f \( -name '*.cpp' -o -name '*.cc' -o -name '*.c' \) \
    ! -path '*/test/*' \
    ! -path '*/.git/*' \
    ! -path '*/build/*' \
    ! -name 'zsign.cpp' \
    ! -name 'iowin32.c' \
    | sort
)

[[ ${#SOURCES[@]} -gt 0 ]] || die "zsign 源码里找不到任何源文件，仓库结构可能变了"
info "zsign 源文件 ${#SOURCES[@]} 个（已排除 zsign.cpp 与 Windows 专用的 iowin32.c）"

SHIM_SOURCES=("${SHIM_DIR}/zsign_shim.cpp")
[[ -f "${SHIM_SOURCES[0]}" ]] || die "找不到 ${SHIM_SOURCES[0]}"

# ---------------------------------------------------------------------------
# 4. 逐平台交叉编译
# ---------------------------------------------------------------------------
build_platform() {
  local platform="$1"
  local sdk_path archs min_flag
  local arch_args=()

  sdk_path="$(xcrun --sdk "${platform}" --show-sdk-path 2>/dev/null)" \
    || die "找不到 ${platform} 的 SDK"
  archs="$(archs_for "${platform}")"
  min_flag="$(min_flag_for "${platform}")"
  for a in ${archs}; do arch_args+=(-arch "${a}"); done

  bold "[4/5] 编译 libzsign.a（${platform} / ${archs} / iOS ${IOS_MIN}）"

  local obj_dir="${BUILD}/obj-zsign-${platform}"
  local lib_dir="${ZSIGN_OUT}/lib/${platform}"
  rm -rf "${obj_dir}" && mkdir -p "${obj_dir}" "${lib_dir}"

  compile_one() {
    local src="$1"
    local tag="$2"
    local obj="${obj_dir}/${tag}.o"

    # .c 用 clang，.cpp/.cc 用 clang++。
    # 用 clang++ 编 .c 会让 clang 把 C 当 C++ 处理，是 deprecated 行为，
    # 遇到 C 里合法的构造（如隐式 void* 转换）会直接报错。
    local compiler="clang++"
    local std_flags=(-std=c++17 -fexceptions -frtti)
    case "${src}" in
      *.c)
        compiler="clang"
        std_flags=(-std=gnu11)
        ;;
    esac

    xcrun --sdk "${platform}" "${compiler}" -c "${src}" \
      "${arch_args[@]}" \
      -isysroot "${sdk_path}" \
      "${min_flag}" \
      -O2 -fPIC -DNDEBUG \
      "${std_flags[@]}" \
      "${INCLUDES[@]}" \
      -o "${obj}" || die "编译失败（${platform}）${src}"
  }

  local index=0
  local total=$(( ${#SOURCES[@]} + ${#SHIM_SOURCES[@]} ))

  for src in "${SOURCES[@]}"; do
    index=$(( index + 1 ))
    printf '\r  编译 %d/%d  %s\033[K' "${index}" "${total}" "$(basename "${src}")"
    compile_one "${src}" "z$(basename "${src}")"
  done

  for src in "${SHIM_SOURCES[@]}"; do
    index=$(( index + 1 ))
    printf '\r  编译 %d/%d  %s\033[K' "${index}" "${total}" "$(basename "${src}")"
    compile_one "${src}" "shim"
  done
  printf '\r\033[K'

  libtool -static -o "${lib_dir}/libzsign.a" "${obj_dir}"/*.o 2>/dev/null \
    || ar rcs "${lib_dir}/libzsign.a" "${obj_dir}"/*.o

  [[ -f "${lib_dir}/libzsign.a" ]] || die "${platform} 的 libzsign.a 生成失败"

  # 确认 shim 符号真的进去了
  if ! nm -gU "${lib_dir}/libzsign.a" 2>/dev/null | grep -q '_zsign_shim_sign_folder'; then
    echo "  警告：${platform} 的静态库里找不到 _zsign_shim_sign_folder 符号"
  fi

  info "$(du -h "${lib_dir}/libzsign.a" | cut -f1)  lib/${platform}/libzsign.a"
}

for platform in ${PLATFORMS}; do
  build_platform "${platform}"
done

# ---------------------------------------------------------------------------
# 5. 导出头文件
# ---------------------------------------------------------------------------
bold "[5/5] 导出桥接头文件"
# 只导出桥接层需要的那一个头文件
cp "${SHIM_DIR}/zsign_shim.h" "${ZSIGN_OUT}/include/"
[[ -f "${ZSIGN_OUT}/include/zsign_shim.h" ]] || die "zsign_shim.h 未导出"
info "Vendor/zsign/include/zsign_shim.h"

echo
bold "完成"
echo
