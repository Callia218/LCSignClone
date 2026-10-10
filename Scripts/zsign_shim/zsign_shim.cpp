/*
 * zsign_shim.cpp — 把 zsign 的 C++ API 包成 C ABI
 *
 * 依赖的 zsign 接口（zhlynn/zsign 的 src/ 目录）：
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
 * Init 的第二个参数（strPKeyFile）内部会依次尝试 PEM 私钥、DER 私钥，
 * 最后按 PKCS#12 解析 —— 所以传 p12 路径即可，第一个参数留空。
 */

#include "zsign_shim.h"

#include "bundle.h"
#include "openssl.h"

#include <openssl/pkcs12.h>
#include <openssl/provider.h>
#include <openssl/x509.h>

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
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

char *Duplicate(const char *value) {
    if (value == nullptr || *value == '\0') { return nullptr; }
    const size_t length = std::strlen(value);
    char *copy = static_cast<char *>(std::malloc(length + 1));
    if (copy == nullptr) { return nullptr; }
    std::memcpy(copy, value, length + 1);
    return copy;
}

/*
 * 把 UTC 的 (年, 月, 日) 换算成「1970-01-01 起的天数」。
 * Howard Hinnant 的 days_from_civil，纯整数运算，无任何 libc 依赖。
 *
 * 为什么不直接用 timegm：编译加了 -std=c++17，clang 会定义 __STRICT_ANSI__，
 * Darwin 的 <time.h> 在那时会退回 _ANSI_SOURCE 级别，把 timegm 的声明藏起来，
 * 于是 "use of undeclared identifier 'timegm'" 直接编译失败。
 */
long long DaysFromCivil(long long year, unsigned month, unsigned day) {
    year -= (month <= 2u) ? 1 : 0;
    const long long era = (year >= 0 ? year : year - 399) / 400;
    const unsigned year_of_era = static_cast<unsigned>(year - era * 400);
    const unsigned day_of_year =
        (153u * (month + (month > 2u ? -3 : 9)) + 2u) / 5u + day - 1u;
    const unsigned day_of_era =
        year_of_era * 365u + year_of_era / 4u - year_of_era / 100u + day_of_year;
    return era * 146097LL + static_cast<long long>(day_of_era) - 719468LL;
}

double Asn1TimeToUnix(const ASN1_TIME *time) {
    if (time == nullptr) { return 0.0; }

    struct tm broken_down;
    std::memset(&broken_down, 0, sizeof(broken_down));
    if (ASN1_TIME_to_tm(time, &broken_down) != 1) { return 0.0; }

    const long long days = DaysFromCivil(broken_down.tm_year + 1900LL,
                                         static_cast<unsigned>(broken_down.tm_mon) + 1u,
                                         static_cast<unsigned>(broken_down.tm_mday));
    const long long seconds = days * 86400LL
                            + static_cast<long long>(broken_down.tm_hour) * 3600LL
                            + static_cast<long long>(broken_down.tm_min) * 60LL
                            + static_cast<long long>(broken_down.tm_sec);

    return (seconds > 0) ? static_cast<double>(seconds) : 0.0;
}

} // namespace

/* ==========================================================================
 * 签名
 * ========================================================================== */

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
            ToString(p12_path),            // strPKeyFile：传 p12，Init 走 PKCS#12 分支
            ToString(provision_path),      // strProvFile：必需
            ToString(entitlements_path),   // strEntitleFile：可空
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
            true,    // bForce：目标可能带旧签名，强制重签
            false,   // bWeakInject
            false,   // bEnableCache
            false    // bRemoveProvision：保留描述文件，安装时需要
        );

        if (!ok) {
            SetError(error_out,
                     "签名失败。最常见原因是 entitlements 超出描述文件授权范围，"
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

/* ==========================================================================
 * p12 解析
 *
 * iOS 上没有 SecCertificateCopyValues / kSecOIDX509V1Validity*，
 * 拿不到证书的 Team ID 和有效期。这里复用 zsign 已经链进来的 OpenSSL。
 * ========================================================================== */

extern "C" int zsign_shim_inspect_p12(const char *p12_path,
                                      const char *password,
                                      zsign_shim_p12_info *info_out,
                                      char **error_out)
{
    if (error_out != nullptr) { *error_out = nullptr; }
    if (info_out == nullptr) {
        SetError(error_out, "内部错误：info_out 为空。");
        return 0;
    }
    std::memset(info_out, 0, sizeof(*info_out));

    if (p12_path == nullptr || *p12_path == '\0') {
        SetError(error_out, "缺少 p12 文件路径。");
        return 0;
    }

    // 有些老证书用的是 RC2/3DES，需要 legacy provider 才能解析
    OSSL_PROVIDER_load(nullptr, "legacy");
    OSSL_PROVIDER_load(nullptr, "default");

    FILE *file = std::fopen(p12_path, "rb");
    if (file == nullptr) {
        SetError(error_out, "无法打开 p12 文件。");
        return 0;
    }

    PKCS12 *p12 = d2i_PKCS12_fp(file, nullptr);
    std::fclose(file);

    if (p12 == nullptr) {
        SetError(error_out, "p12 文件格式无效，无法解析。");
        return 0;
    }

    EVP_PKEY *private_key = nullptr;
    X509 *certificate = nullptr;
    STACK_OF(X509) *chain = nullptr;

    const char *passphrase = (password != nullptr) ? password : "";
    const int parsed = PKCS12_parse(p12, passphrase, &private_key, &certificate, &chain);
    PKCS12_free(p12);

    if (parsed != 1 || certificate == nullptr) {
        if (private_key != nullptr) { EVP_PKEY_free(private_key); }
        if (certificate != nullptr) { X509_free(certificate); }
        if (chain != nullptr) { sk_X509_pop_free(chain, X509_free); }
        SetError(error_out, "p12 解析失败，导出密码可能不正确。");
        return 0;
    }

    X509_NAME *subject = X509_get_subject_name(certificate);
    char buffer[1024];

    if (subject != nullptr) {
        if (X509_NAME_get_text_by_NID(subject, NID_commonName, buffer, sizeof(buffer)) > 0) {
            info_out->common_name = Duplicate(buffer);
        }
        if (X509_NAME_get_text_by_NID(subject, NID_organizationalUnitName,
                                      buffer, sizeof(buffer)) > 0) {
            info_out->team_id = Duplicate(buffer);
        }
    }

    info_out->not_before = Asn1TimeToUnix(X509_get0_notBefore(certificate));
    info_out->not_after  = Asn1TimeToUnix(X509_get0_notAfter(certificate));

    EVP_PKEY_free(private_key);
    X509_free(certificate);
    if (chain != nullptr) { sk_X509_pop_free(chain, X509_free); }

    if (info_out->not_after == 0.0) {
        SetError(error_out, "p12 解析成功但读不到有效期，证书可能已损坏。");
        return 0;
    }

    return 1;
}

extern "C" void zsign_shim_free_p12_info(zsign_shim_p12_info *info) {
    if (info == nullptr) { return; }
    if (info->common_name != nullptr) { std::free(info->common_name); }
    if (info->team_id != nullptr) { std::free(info->team_id); }
    std::memset(info, 0, sizeof(*info));
}

extern "C" void zsign_shim_free(char *ptr) {
    std::free(ptr);
}
