/*
 * zsign_shim.cpp — 把 zsign 的 C++ API 包成 C ABI
 *
 * 依赖的 zsign 接口（对应 zhlynn/zsign 的 src/ 目录）：
 *
 *   class ZSignAsset {
 *       bool Init(const string& strCertFile, const string& strPKeyFile,
 *                 const string& strProvFile, const string& strEntitleFile,
 *                 const string& strPassword, bool bAdhoc,
 *                 bool bSHA256Only, bool bSingleBinary);
 *   };
 *
 *   class ZBundle {
 *       bool SignFolder(ZSignAsset* pSignAsset, const string& strFolder,
 *                       const string& strBundleId, const string& strBundleVersion,
 *                       const string& strDisplayName,
 *                       const vector<string>& arrDylibFiles,
 *                       const vector<string>& arrRemoveDylibNames,
 *                       bool bForce, bool bWeakInject, bool bEnableCache,
 *                       bool bRemoveProvision = false);
 *   };
 *
 * Init 的第二个参数（strPKeyFile）内部会依次尝试 PEM 私钥、DER 私钥、
 * 最后按 PKCS#12 解析 —— 所以传 p12 路径即可，第一个参数留空。
 */

#include "zsign_shim.h"

#include "bundle.h"
#include "openssl.h"

#include <cstdlib>
#include <cstring>
#include <exception>
#include <string>
#include <vector>

namespace {

std::string ToString(const char *value) {
    return (value != nullptr) ? std::string(value) : std::string();
}

void SetError(char **out, const std::string &message) {
    if (out == nullptr) { return; }
    char *copy = static_cast<char *>(std::malloc(message.size() + 1));
    if (copy == nullptr) { return; }
    std::memcpy(copy, message.c_str(), message.size() + 1);
    *out = copy;
}

} // namespace

extern "C" int zsign_shim_sign_folder(const char *folder,
                                      const char *p12_path,
                                      const char *password,
                                      const char *provision_path,
                                      const char *entitlements_path,
                                      const char *bundle_id,
                                      const char *bundle_version,
                                      const char *display_name,
                                      const char *const *dylib_paths,
                                      int dylib_count,
                                      char **error_out)
{
    if (error_out != nullptr) { *error_out = nullptr; }

    if (folder == nullptr || *folder == '\0') {
        SetError(error_out, "缺少待签名的 .app 目录路径。");
        return 0;
    }
    if (p12_path == nullptr || *p12_path == '\0') {
        SetError(error_out, "缺少 p12 证书路径。");
        return 0;
    }
    if (provision_path == nullptr || *provision_path == '\0') {
        SetError(error_out,
                 "缺少描述文件。zsign 在非 adhoc 模式下必须提供 mobileprovision，"
                 "它需要从描述文件里读取 TeamId。");
        return 0;
    }

    try {
        ZSignAsset asset;
        const bool inited = asset.Init(
            std::string(),                 // strCertFile：p12 内已含证书链，留空
            ToString(p12_path),            // strPKeyFile：传 p12，Init 会走 PKCS#12 分支
            ToString(provision_path),      // strProvFile：必需
            ToString(entitlements_path),   // strEntitleFile：可空，空则从描述文件提取
            ToString(password),            // strPassword
            false,                         // bAdhoc
            false,                         // bSHA256Only
            false                          // bSingleBinary
        );

        if (!inited) {
            SetError(error_out,
                     "证书或描述文件加载失败。请依次检查："
                     "1) p12 导出密码是否正确；"
                     "2) 描述文件与证书的 Team ID 是否一致；"
                     "3) 描述文件是否已过期。");
            return 0;
        }

        std::vector<std::string> dylibs;
        for (int i = 0; i < dylib_count; ++i) {
            if (dylib_paths == nullptr) { break; }
            const char *path = dylib_paths[i];
            if (path != nullptr && *path != '\0') {
                dylibs.push_back(std::string(path));
            }
        }

        const std::vector<std::string> remove_dylibs;   // 不主动移除任何 dylib

        ZBundle bundle;
        const bool ok = bundle.SignFolder(
            &asset,
            ToString(folder),
            ToString(bundle_id),
            ToString(bundle_version),
            ToString(display_name),
            dylibs,
            remove_dylibs,
            true,    // bForce：目标可能带着旧签名，强制重签
            false,   // bWeakInject
            false,   // bEnableCache
            false    // bRemoveProvision：保留描述文件，安装时需要它
        );

        if (!ok) {
            SetError(error_out,
                     "签名失败。最常见的原因是 entitlements 超出描述文件授权范围，"
                     "或目标 App 的 Bundle ID 不被描述文件的 App ID 覆盖。");
            return 0;
        }

        return 1;

    } catch (const std::exception &e) {
        SetError(error_out, std::string("签名过程抛出异常：") + e.what());
        return 0;
    } catch (...) {
        SetError(error_out, "签名过程抛出未知异常。");
        return 0;
    }
}

extern "C" void zsign_shim_free(char *ptr) {
    std::free(ptr);
}
