#!/usr/bin/env bash
# 阶段 0：用命令行验证签名链路。不写一行 UI，先确认「证书 + 描述文件 + zsign」能签出可安装的包。
#
# 用法：
#   ./Scripts/20_resign_cli.sh \
#       --ipa  input.ipa \
#       --p12  cert.p12 \
#       --pass 'p12-password' \
#       --prov profile.mobileprovision \
#       --out  output.ipa
#
# 可选：
#   --ent  entitlements.plist    自定义权限文件
#   --bundle-id  com.foo.bar     改 Bundle ID
#   --name  "新名称"             改显示名
#   --dylib  hook.dylib          注入 dylib（可重复）
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/.build"
ZSIGN_BIN="$BUILD/zsign-bin/zsign"

IPA="" P12="" PASS="" PROV="" OUT="" ENT="" BUNDLE_ID="" NAME=""
DYLIB=()

bold() { printf '\033[1m%s\033[0m\n' "$1"; }
step() { printf '\n\033[36m▸ %s\033[0m\n' "$1"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
die()  { printf '\n\033[31m错误: %s\033[0m\n' "$1" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ipa)       IPA="$2"; shift 2 ;;
    --p12)       P12="$2"; shift 2 ;;
    --pass)      PASS="$2"; shift 2 ;;
    --prov)      PROV="$2"; shift 2 ;;
    --out)       OUT="$2"; shift 2 ;;
    --ent)       ENT="$2"; shift 2 ;;
    --bundle-id) BUNDLE_ID="$2"; shift 2 ;;
    --name)      NAME="$2"; shift 2 ;;
    --dylib)     DYLIB+=("$2"); shift 2 ;;
    -h|--help)   sed -n '2,18p' "$0"; exit 0 ;;
    *)           die "未知参数: $1" ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || die "只能在 macOS 上运行"
[[ -n "$IPA"  ]] || die "缺少 --ipa"
[[ -n "$P12"  ]] || die "缺少 --p12"
[[ -n "$PROV" ]] || die "缺少 --prov（只有 p12 是签不出来的）"
[[ -n "$OUT"  ]] || die "缺少 --out"

for f in "$IPA" "$P12" "$PROV"; do
  [[ -f "$f" ]] || die "文件不存在: $f"
done

# ---------------------------------------------------------------------------
# 1. 准备 zsign 可执行文件（macOS 版）
# ---------------------------------------------------------------------------
step "准备 zsign"

# 兜底路径：从源码编译。
# zsign 的 Makefile 在 build/<平台>/ 下，**不在仓库根目录** ——
# 在根目录直接 make 只会得到 "No targets specified and no makefile found"。
build_zsign_from_source() {
  SRC="$BUILD/zsign-src"
  if [[ ! -d "$SRC/.git" ]]; then
    git clone --depth 1 https://github.com/zhlynn/zsign.git "$SRC" \
      || die "clone zsign 失败，检查网络"
  fi

  MAKE_DIR="$SRC/build/macos"
  [[ -f "$MAKE_DIR/Makefile" ]] \
    || die "找不到 $MAKE_DIR/Makefile，zsign 仓库结构可能变了"

  command -v pkg-config >/dev/null 2>&1 \
    || die "未找到 pkg-config，执行：brew install pkg-config"

  # Makefile 靠 pkg-config 定位 OpenSSL（OPENSSL_INCLUDE / OPENSSL_LIB）。
  # openssl@3 是 keg-only，不把它的 pkgconfig 目录塞进 PKG_CONFIG_PATH，
  # pkg-config --cflags openssl 会直接失败，编译命令里就一条 OpenSSL 参数都没有。
  OPENSSL_PREFIX="$(brew --prefix openssl@3 2>/dev/null || true)"
  [[ -n "$OPENSSL_PREFIX" && -d "$OPENSSL_PREFIX" ]] \
    || die "未找到 openssl@3，执行：brew install openssl@3"

  export PKG_CONFIG_PATH="$OPENSSL_PREFIX/lib/pkgconfig:${PKG_CONFIG_PATH:-}"
  pkg-config --exists openssl \
    || die "pkg-config 找不到 openssl，检查 PKG_CONFIG_PATH=$PKG_CONFIG_PATH"
  ok "OpenSSL: $(pkg-config --modversion openssl)"

  (
    cd "$MAKE_DIR"
    make clean >/dev/null 2>&1 || true
    make
  ) || die "zsign 编译失败"

  # Makefile 里 BINDIR = ../../bin，即 <SRC>/bin/zsign
  bin="$SRC/bin/zsign"
  if [[ ! -x "$bin" ]]; then
    bin="$(find "$SRC" -maxdepth 3 -type f -name zsign -perm -u+x | head -1)"
  fi
  [[ -n "$bin" && -x "$bin" ]] || die "编译完成但找不到 zsign 可执行文件"
  cp "$bin" "$ZSIGN_BIN"
}

# 首选路径：官方 release 的预编译二进制。
# 好处是版本固定、带 SHA256 校验、不用在本机装 pkg-config / openssl@3，
# CI 上也能省掉一次完整编译。
# 注意：官方只发布了 macOS **arm64** 版本，Intel 机器没有对应资产。
ZSIGN_VERSION="${ZSIGN_VERSION:-v1.1.2}"

download_zsign_release() {
  local host_arch asset base dir expected actual
  host_arch="$(uname -m)"
  case "$host_arch" in
    arm64|aarch64) asset="zsign-macos-arm64.tar.gz" ;;
    *) return 1 ;;
  esac

  base="https://github.com/zhlynn/zsign/releases/download/${ZSIGN_VERSION}"
  dir="$BUILD/zsign-bin"

  curl -fsSL -o "$dir/$asset" "$base/$asset" || return 1
  curl -fsSL -o "$dir/SHA256SUMS.txt" "$base/SHA256SUMS.txt" || return 1

  expected="$(awk -v n="$asset" '$2 == n { print $1 }' "$dir/SHA256SUMS.txt" | head -1)"
  actual="$(shasum -a 256 "$dir/$asset" | awk '{print $1}')"

  if [[ -z "$expected" || "$expected" != "$actual" ]]; then
    bad "SHA256 校验不通过（期望 ${expected:-空}，实际 $actual）"
    return 1
  fi

  # 归档里就是单个 zsign 可执行文件
  tar -xzf "$dir/$asset" -C "$dir" zsign || return 1
  chmod +x "$dir/zsign" || return 1
  ok "已使用官方预编译版本 ${ZSIGN_VERSION}（SHA256 校验通过）"
  return 0
}

if [[ -x "$ZSIGN_BIN" ]]; then
  ok "已存在 $ZSIGN_BIN"
else
  mkdir -p "$BUILD/zsign-bin"
  if download_zsign_release; then
    :
  else
    bad "预编译版本不可用，回退到源码编译"
    build_zsign_from_source
  fi
fi

# ---------------------------------------------------------------------------
# 2. 预检：p12 与描述文件的 Team ID 必须一致
# ---------------------------------------------------------------------------
step "校验证书与描述文件配对"

# macOS 钥匙串导出的 p12 常带 3DES/RC2 这类 legacy 加密，OpenSSL 3 默认不认，
# 得加 -legacy。所以先按默认试一次，不行再退回 legacy。
p12_team=""
for extra in "" "-legacy"; do
  p12_team="$(openssl pkcs12 -in "$P12" -nokeys -clcerts -passin "pass:$PASS" $extra 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | grep -o 'OU *= *[A-Za-z0-9]*' | head -1 | sed 's/.*= *//' || true)"
  if [[ -n "$p12_team" ]]; then break; fi
done

prov_team="$(security cms -D -i "$PROV" 2>/dev/null \
  | plutil -extract TeamIdentifier.0 raw - 2>/dev/null || true)"
app_id="$(security cms -D -i "$PROV" 2>/dev/null \
  | plutil -extract Entitlements.application-identifier raw - 2>/dev/null || true)"
prov_exp="$(security cms -D -i "$PROV" 2>/dev/null \
  | plutil -extract ExpirationDate raw - 2>/dev/null || true)"

[[ -n "$prov_team" ]] || die "描述文件解析失败，确认是 .mobileprovision 而不是 .p12"
ok "描述文件 Team ID : $prov_team"
ok "描述文件 App ID  : ${app_id:-（无）}"
ok "描述文件过期时间 : ${prov_exp:-未知}"

if [[ -z "$p12_team" ]]; then
  bad "无法从 p12 提取 Team ID —— 密码可能不对"
  die "请确认 --pass 参数"
fi
ok "证书 Team ID     : $p12_team"

if [[ "$p12_team" != "$prov_team" ]]; then
  bad "Team ID 不一致：证书=$p12_team  描述文件=$prov_team"
  die "两者必须配对，否则签出来的包装不上"
fi
ok "配对校验通过"

# ---------------------------------------------------------------------------
# 2b. 预检：描述文件的 App ID 必须能覆盖目标 Bundle ID
#
# 这是重签名失败里最常见、也最难自查的一类 —— Team 对得上、密码也对，
# 但描述文件是 com.yourteam.myapp 而目标 App 是 com.example.whatever，
# zsign 跑到一半才失败，报错还相当含糊。
# ---------------------------------------------------------------------------
step "校验 App ID 覆盖范围"

# 目标 Bundle ID：--bundle-id 指定了就按它算，否则从 IPA 的 Info.plist 里读
target_bid="$BUNDLE_ID"
if [[ -z "$target_bid" ]]; then
  # 先落盘再读 —— plutil 从 stdin 读二进制 plist 的行为各版本不一致
  tmp_plist="$(mktemp)"
  if unzip -p "$IPA" 'Payload/*/Info.plist' > "$tmp_plist" 2>/dev/null \
     && [[ -s "$tmp_plist" ]]; then
    target_bid="$(plutil -extract CFBundleIdentifier raw "$tmp_plist" 2>/dev/null || true)"
  fi
  rm -f "$tmp_plist"
fi

if [[ -z "$app_id" ]]; then
  bad "描述文件里读不到 application-identifier，跳过覆盖性检查"
elif [[ -z "$target_bid" ]]; then
  bad "读不到目标 App 的 Bundle ID，跳过覆盖性检查"
else
  # application-identifier 形如 TEAMID.* 或 TEAMID.com.example.app，去掉 Team 前缀
  pattern="${app_id#*.}"
  covered="no"

  if [[ "$pattern" == "*" ]]; then
    covered="yes"
  elif [[ "$pattern" == *".*" ]]; then
    prefix="${pattern%.\*}"
    if [[ "$target_bid" == "$prefix" || "$target_bid" == "$prefix".* ]]; then
      covered="yes"
    fi
  elif [[ "$target_bid" == "$pattern" ]]; then
    covered="yes"
  fi

  if [[ "$covered" == "yes" ]]; then
    ok "App ID（$app_id）覆盖目标 Bundle ID（$target_bid）"
  else
    bad "描述文件 App ID（$app_id）覆盖不了目标 Bundle ID（$target_bid）"
    die "两个办法：加 --bundle-id 指定一个被覆盖的 ID；或在开发者后台为这个 Bundle ID 新建描述文件"
  fi
fi

# ---------------------------------------------------------------------------
# 3. 执行签名
# ---------------------------------------------------------------------------
step "执行签名"
mkdir -p "$(dirname "$OUT")"

# -z 是 --zip_level，**必须带值（0-9）**。
# 写成裸的 -z 会把后面的输入 IPA 路径当成压缩级别吃掉，命令里就没有输入文件了。
args=(-k "$P12" -m "$PROV" -o "$OUT" -z 6)
if [[ -n "$PASS" ]]; then args+=(-p "$PASS"); fi
if [[ -n "$ENT"  ]]; then args+=(-e "$ENT");  fi
if [[ -n "$BUNDLE_ID" ]]; then args+=(-b "$BUNDLE_ID"); fi
if [[ -n "$NAME" ]]; then args+=(-n "$NAME"); fi
for d in ${DYLIB[@]+"${DYLIB[@]}"}; do
  if [[ -n "$d" ]]; then args+=(-l "$d"); fi
done
args+=("$IPA")

# 回显时把密码遮掉。注意别用 ${args[*]//$PASS/...} —— PASS 为空时
# 空模式串会让 bash 到处插替换内容。
display="${args[*]}"
if [[ -n "$PASS" ]]; then display="${display//$PASS/******}"; fi
echo "  zsign $display"
echo

if "$ZSIGN_BIN" "${args[@]}"; then
  ok "签名完成"
else
  bad "签名失败，排查顺序："
  cat <<'EOF'
      1. p12 密码是否正确
      2. entitlements 是否超出描述文件授权范围（最常见）
      3. Bundle ID 是否被描述文件的 App ID 覆盖
      4. 描述文件是否已过期
      5. 加 -d 参数重跑 zsign 看详细日志
EOF
  exit 1
fi

# ---------------------------------------------------------------------------
# 4. 验证产物
# ---------------------------------------------------------------------------
step "验证产物"
[[ -f "$OUT" ]] || die "输出文件未生成"

WORK="$BUILD/verify"
rm -rf "$WORK" && mkdir -p "$WORK"
unzip -qo "$OUT" -d "$WORK"

APP="$(find "$WORK/Payload" -maxdepth 1 -name '*.app' | head -1)"
[[ -n "$APP" ]] || die "产物里找不到 .app"

[[ -d "$APP/_CodeSignature" ]] && ok "存在 _CodeSignature/" || bad "缺少 _CodeSignature/"
[[ -f "$APP/embedded.mobileprovision" ]] && ok "存在 embedded.mobileprovision" || bad "缺少 embedded.mobileprovision"

exe="$(plutil -extract CFBundleExecutable raw "$APP/Info.plist" 2>/dev/null || true)"
if [[ -n "$exe" && -f "$APP/$exe" ]]; then
  if codesign -dv "$APP/$exe" 2>&1 | grep -q 'Signature=adhoc'; then
    bad "主程序是 ad-hoc 签名，证书未生效"
  else
    ok "主程序已签名"
    codesign -dv "$APP/$exe" 2>&1 | sed 's/^/       /' | head -5
  fi
fi

echo
bold "阶段 0 完成"
echo "  产物：$OUT"
echo
echo "下一步：把它装进真机（Xcode > Devices and Simulators 拖入，或 Apple Configurator）。"
echo "  装得上 + 能启动 = 阶段 0 通过，可以开始写 App。"
echo
