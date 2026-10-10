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
 */

#ifndef ZSIGN_SHIM_H
#define ZSIGN_SHIM_H

#ifdef __cplusplus
extern "C" {
#endif

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

/* 释放 zsign_shim_sign_folder 写出的错误字符串 */
void zsign_shim_free(char *ptr);

#ifdef __cplusplus
}
#endif

#endif /* ZSIGN_SHIM_H */
