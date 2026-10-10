/*
 * zsign_shim.h — zsign C++ 引擎的纯 C 门面
 *
 * 为什么要这一层：
 * zsign 的公开 API（ZSignAsset / ZBundle）定义在 bundle.h / openssl.h 里，
 * 而这些头文件会连带引入 json.h、common.h 以及 OpenSSL 的头文件。
 * 如果让 Objective-C++ 直接 include 它们，整个依赖链会被拖进 Xcode 的
 * 编译单元，一旦 OpenSSL 头文件路径对不上就编译失败。
 *
 * 这一层把依赖封在 .cpp 里，对外只暴露 C ABI，桥接层因此完全干净。
 *
 * 本文件是**唯一来源**：10_build_zsign.sh 编译它，并把它拷到
 * Vendor/zsign/include/ 供 Xcode 侧的桥接层 include。
 */

#ifndef ZSIGN_SHIM_H
#define ZSIGN_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

/* ==========================================================================
 * 签名
 * ========================================================================== */

/*
 * 对已解包的 .app 目录执行签名。
 *
 * folder              .app 目录路径（不是 IPA，是解包后的目录）
 * p12_path            p12 证书路径。zsign 会走 PKCS#12 分支解析
 * password            p12 导出密码，无密码传空串
 * provision_path      描述文件路径。**必需** —— zsign 在非 adhoc 模式下
 *                     没有描述文件会直接失败，因为要从里面取 TeamId
 * entitlements_path   自定义 entitlements plist，可为 NULL（则从描述文件取）
 * bundle_id           改写 Bundle ID，可为 NULL
 * bundle_version      改写版本号，可为 NULL
 * display_name        改写显示名，可为 NULL
 * dylib_paths         需要注入的 dylib 路径数组，可为 NULL
 * dylib_count         dylib 数量
 * error_out           失败时写入错误信息（需用 zsign_shim_free 释放），可为 NULL
 *
 * 返回 1 表示成功，0 表示失败。
 */
int zsign_shim_sign_folder(const char *folder,
                           const char *p12_path,
                           const char *password,
                           const char *provision_path,
                           const char *entitlements_path,
                           const char *bundle_id,
                           const char *bundle_version,
                           const char *display_name,
                           const char *const *dylib_paths,
                           int dylib_count,
                           char **error_out);

/* ==========================================================================
 * p12 解析
 *
 * iOS 上没有 SecCertificateCopyValues / kSecOIDX509V1Validity* 这些 API
 * （它们是 macOS 独有的），拿不到证书的 Team ID 和有效期。
 * 与其在 Swift 侧堆平台分支，不如复用 zsign 已经链进来的 OpenSSL。
 * ========================================================================== */

/*
 * 从 p12 里读出的证书信息。
 * 两个字符串由本层分配，用完必须调 zsign_shim_free_p12_info 释放。
 * 时间为 Unix 时间戳（秒），解析失败时为 0。
 */
typedef struct {
    char  *common_name;   /* 证书 subject 的 CN，用于展示 */
    char  *team_id;       /* 证书 subject 的 OU，即 Apple Team ID */
    double not_before;
    double not_after;
} zsign_shim_p12_info;

/*
 * 解析 p12，读取证书 CN / Team ID / 有效期。
 *
 * p12_path    p12 文件路径
 * password    导出密码，可为 NULL（等同于空串）
 * info_out    输出参数，必须非 NULL。无论成功失败都会被清零或填好
 * error_out   失败时写入错误信息（需用 zsign_shim_free 释放），可为 NULL
 *
 * 返回 1 表示成功，0 表示失败。
 */
int zsign_shim_inspect_p12(const char *p12_path,
                           const char *password,
                           zsign_shim_p12_info *info_out,
                           char **error_out);

/* 释放 zsign_shim_inspect_p12 填出的内容（可安全重复调用） */
void zsign_shim_free_p12_info(zsign_shim_p12_info *info);

/* 释放本层写出的错误字符串 */
void zsign_shim_free(char *ptr);

#ifdef __cplusplus
}
#endif

#endif /* ZSIGN_SHIM_H */
