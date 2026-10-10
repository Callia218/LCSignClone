#!/usr/bin/env bash
# 环境自检：确认这台机器具备编译 iOS 重签名 App 的条件
set -uo pipefail

ok=0
fail=0

pass() { printf '  \033[32m✓\033[0m %s\n' "$1"; ok=$((ok+1)); }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; fail=$((fail+1)); }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }

echo
echo "== 系统 =="
if [[ "$(uname -s)" == "Darwin" ]]; then
  pass "macOS $(sw_vers -productVersion)"
else
  bad "当前系统是 $(uname -s)，本项目只能在 macOS 上构建"
fi

echo
echo "== 工具链 =="
if xcode-select -p >/dev/null 2>&1; then
  pass "Xcode 命令行工具：$(xcode-select -p)"
else
  bad "未安装 Xcode 命令行工具，执行：xcode-select --install"
fi

if command -v xcodebuild >/dev/null 2>&1; then
  pass "xcodebuild $(xcodebuild -version 2>/dev/null | head -1 | awk '{print $2}')"
else
  bad "找不到 xcodebuild"
fi

for t in git cmake make curl; do
  if command -v "$t" >/dev/null 2>&1; then pass "$t"; else bad "缺少 $t"; fi
done

if command -v xcodegen >/dev/null 2>&1; then
  pass "xcodegen $(xcodegen --version 2>/dev/null | awk '{print $NF}')"
else
  bad "缺少 xcodegen，执行：brew install xcodegen"
fi

if command -v openssl >/dev/null 2>&1; then
  pass "openssl（用于验证 p12 / 描述文件）"
else
  warn "未找到 openssl，排查证书问题时可能需要"
fi

echo
echo "== 目标架构 =="
if xcrun --sdk iphoneos --show-sdk-version >/dev/null 2>&1; then
  pass "iOS SDK $(xcrun --sdk iphoneos --show-sdk-version)"
else
  bad "找不到 iOS SDK"
fi

echo
echo "== 证书检查 =="
if [[ $# -ge 1 ]]; then
  p12="$1"
  if [[ -f "$p12" ]]; then
    if openssl pkcs12 -in "$p12" -noout -passin pass: 2>/dev/null; then
      pass "p12 可读（无密码）"
    else
      warn "p12 有密码保护，这是正常的"
    fi
    subject=$(openssl pkcs12 -in "$p12" -nokeys -clcerts -passin pass: 2>/dev/null \
              | openssl x509 -noout -subject 2>/dev/null)
    [[ -n "$subject" ]] && echo "       subject: $subject"
  else
    bad "找不到文件 $p12"
  fi
fi

if [[ $# -ge 2 ]]; then
  prov="$2"
  if [[ -f "$prov" ]]; then
    team=$(security cms -D -i "$prov" 2>/dev/null \
           | plutil -extract TeamIdentifier.0 raw - 2>/dev/null)
    appid=$(security cms -D -i "$prov" 2>/dev/null \
            | plutil -extract Entitlements.application-identifier raw - 2>/dev/null)
    exp=$(security cms -D -i "$prov" 2>/dev/null \
          | plutil -extract ExpirationDate raw - 2>/dev/null)
    if [[ -n "$team" ]]; then
      pass "描述文件可解析"
      echo "       Team ID      : $team"
      echo "       App ID       : $appid"
      echo "       过期时间     : $exp"
    else
      bad "描述文件解析失败，可能不是有效的 mobileprovision"
    fi
  else
    bad "找不到文件 $prov"
  fi
fi

echo
if [[ $fail -eq 0 ]]; then
  printf '\033[32m全部通过\033[0m（%d 项）\n\n' "$ok"
else
  printf '\033[31m有 %d 项未通过\033[0m，先解决再继续。\n\n' "$fail"
  exit 1
fi

echo "用法补充："
echo "  ./Scripts/00_check_env.sh                       仅检查环境"
echo "  ./Scripts/00_check_env.sh cert.p12              顺带检查证书"
echo "  ./Scripts/00_check_env.sh cert.p12 profile.mobileprovision"
echo
