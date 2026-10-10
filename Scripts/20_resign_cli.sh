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
if [[ -x "$ZSIGN_BIN" ]]; then
  ok "已存在 $ZSIGN_BIN"
else
  mkdir -p "$BUILD/zsign-bin"
  SRC="$BUILD/zsign-src"
  if [[ ! -d "$SRC/.git" ]]; then
    git clone --depth 1 https://github.com/zhlynn/zsign.git "$SRC"
  fi

  OPENSSL_PREFIX="$(brew --prefix openssl@3 2>/dev/null || echo /usr/local/opt/openssl@3)"
  [[ -d "$OPENSSL_PREFIX" ]] || die "未找到 OpenSSL，执行：brew install openssl@3"

  ( cd "$SRC" && make clean >/dev/null 2>&1 || true
    make \
      CFLAGS="-I$OPENSSL_PREFIX/include -O2 -std=c++17" \
      LDFLAGS="-L$OPENSSL_PREFIX/lib -lcrypto -lssl -lz -lbz2 -lc++" ) \
    || die "zsign 编译失败"

  bin="$(find "$SRC" -maxdepth 2 -type f -name zsign -perm -u+x | head -1)"
  [[ -n "$bin" ]] || die "编译完成但找不到 zsign 可执行文件"
  cp "$bin" "$ZSIGN_BIN"
  ok "编译完成"
fi

# ---------------------------------------------------------------------------
# 2. 预检：p12 与描述文件的 Team ID 必须一致
# ---------------------------------------------------------------------------
step "校验证书与描述文件配对"
p12_team="$(openssl pkcs12 -in "$P12" -nokeys -clcerts -passin "pass:$PASS" 2>/dev/null \
  | openssl x509 -noout -subject 2>/dev/null \
  | grep -o 'OU *= *[A-Za-z0-9]*' | head -1 | sed 's/.*= *//' || true)"
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
# 3. 执行签名
# ---------------------------------------------------------------------------
step "执行签名"
mkdir -p "$(dirname "$OUT")"

args=(-k "$P12" -m "$PROV" -o "$OUT" -z)
[[ -n "$PASS" ]] && args+=(-p "$PASS")
[[ -n "$ENT" ]] && args+=(-e "$ENT")
[[ -n "$BUNDLE_ID" ]] && args+=(-b "$BUNDLE_ID")
[[ -n "$NAME" ]] && args+=(-n "$NAME")
for d in "${DYLIB[@]:-}"; do [[ -n "$d" ]] && args+=(-l "$d"); done
args+=("$IPA")

echo "  zsign ${args[*]//$PASS/******}"
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
