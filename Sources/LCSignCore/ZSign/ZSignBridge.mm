#import "ZSignBridge.h"

#include "zsign.h"

#include <string>
#include <vector>

NSString * const ZSignErrorDomain = @"com.example.lcsigncore.zsign";

static std::string ToStd(NSString *_Nullable s) {
    return (s != nil && s.length > 0) ? std::string(s.UTF8String) : std::string();
}

static NSError *MakeError(ZSignErrorCode code, NSString *message, NSString *suggestion) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[NSLocalizedDescriptionKey] = message;
    if (suggestion.length > 0) {
        info[NSLocalizedRecoverySuggestionErrorKey] = suggestion;
    }
    return [NSError errorWithDomain:ZSignErrorDomain code:code userInfo:info];
}

@implementation ZSignBridge

+ (BOOL)signAppAtPath:(NSString *)appPath
              p12Path:(NSString *)p12Path
          p12Password:(NSString *)p12Password
        provisionPath:(NSString *)provisionPath
     entitlementsPath:(NSString *)entitlementsPath
             bundleId:(NSString *)bundleId
        bundleVersion:(NSString *)bundleVersion
          displayName:(NSString *)displayName
             iconFile:(NSString *)iconFile
           dylibPaths:(NSArray<NSString *> *)dylibPaths
                error:(NSError **)error
{
    NSFileManager *fm = NSFileManager.defaultManager;

    if (![fm fileExistsAtPath:appPath]) {
        if (error) {
            *error = MakeError(ZSignErrorFileNotFound,
                               @"找不到待签名的 .app 目录。",
                               [NSString stringWithFormat:@"路径：%@", appPath]);
        }
        return NO;
    }
    if (![fm fileExistsAtPath:p12Path]) {
        if (error) {
            *error = MakeError(ZSignErrorFileNotFound, @"找不到 p12 证书文件。", nil);
        }
        return NO;
    }

    @try {
        // ------------------------------------------------------------------
        // 注意：以下调用的是 zsign 的 C++ 接口。
        // 不同版本的 zsign 参数顺序可能不同，首次编译前请打开
        // Vendor/zsign/include/zsign.h 核对 Init / SignFolder 的签名。
        // 这里按 zsign 6.x 的接口编写。
        // ------------------------------------------------------------------
        ZSignAsset asset;
        bool inited = asset.Init(ToStd(p12Path),
                                 ToStd(p12Password),
                                 ToStd(provisionPath),
                                 ToStd(entitlementsPath),
                                 false,                 // bForce：不强制覆盖已存在的签名
                                 ToStd(bundleId),
                                 ToStd(bundleVersion));

        if (!inited) {
            if (error) {
                *error = MakeError(ZSignErrorBadCredentials,
                                   @"证书或描述文件加载失败。",
                                   @"请依次检查：1) p12 导出密码是否正确；"
                                   @"2) 描述文件与证书的 Team ID 是否一致；"
                                   @"3) 描述文件是否已过期。");
            }
            return NO;
        }

        std::vector<std::string> dylibs;
        for (NSString *d in dylibPaths) {
            if (d.length > 0) { dylibs.push_back(ToStd(d)); }
        }

        bool signed_ok = ZSign::SignFolder(&asset,
                                           ToStd(appPath),
                                           ToStd(bundleId),
                                           ToStd(bundleVersion),
                                           ToStd(displayName),
                                           ToStd(iconFile),
                                           dylibs,
                                           std::string());   // strOutputFile：原地签名，不导出

        if (!signed_ok) {
            if (error) {
                *error = MakeError(ZSignErrorSignFailed,
                                   @"签名失败。",
                                   @"最常见原因是 entitlements 超出描述文件授权范围，"
                                   @"或目标 App 的 Bundle ID 不被描述文件的 App ID 覆盖。");
            }
            return NO;
        }

        return YES;
    }
    @catch (NSException *ex) {
        if (error) {
            *error = MakeError(ZSignErrorSignFailed,
                               @"签名过程抛出异常。",
                               [NSString stringWithFormat:@"%@: %@", ex.name, ex.reason]);
        }
        return NO;
    }
}

@end
