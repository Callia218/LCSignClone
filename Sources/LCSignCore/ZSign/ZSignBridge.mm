#import "ZSignBridge.h"

#include "zsign_shim.h"

#include <cstdlib>

NSString * const ZSignErrorDomain = @"com.example.lcsigncore.zsign";

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

    // 描述文件是硬需求：zsign 要从里面读 TeamId 与 App ID
    if (provisionPath.length > 0 && ![fm fileExistsAtPath:provisionPath]) {
        if (error) {
            *error = MakeError(ZSignErrorFileNotFound, @"找不到描述文件。", nil);
        }
        return NO;
    }

    // ---- 把 dylib 数组摊平成 C 数组 ----
    NSArray<NSString *> *dylibs = dylibPaths ?: @[];
    const NSUInteger dylibCount = dylibs.count;
    const char **cDylibPaths = NULL;

    if (dylibCount > 0) {
        cDylibPaths = static_cast<const char **>(
            std::malloc(sizeof(const char *) * dylibCount)
        );
        if (cDylibPaths == NULL) {
            if (error) {
                *error = MakeError(ZSignErrorSignFailed, @"内存分配失败。", nil);
            }
            return NO;
        }
        for (NSUInteger i = 0; i < dylibCount; i++) {
            cDylibPaths[i] = dylibs[i].UTF8String;
        }
    }

    // ---- 调 shim ----
    char *errorMessage = NULL;

    const int result = zsign_shim_sign_folder(
        appPath.UTF8String,
        p12Path.UTF8String,
        p12Password.UTF8String,          // 空串表示无密码
        provisionPath.UTF8String,        // nil → NULL，shim 会明确报错
        entitlementsPath.UTF8String,     // nil → NULL，从描述文件取
        bundleId.UTF8String,             // nil → NULL，保持原值
        bundleVersion.UTF8String,
        displayName.UTF8String,
        cDylibPaths,
        static_cast<int>(dylibCount),
        &errorMessage
    );

    if (cDylibPaths != NULL) {
        std::free(const_cast<char **>(cDylibPaths));
    }

    if (result != 1) {
        NSString *message = (errorMessage != NULL)
            ? [NSString stringWithUTF8String:errorMessage]
            : @"签名失败，引擎未返回具体原因。";

        if (errorMessage != NULL) {
            zsign_shim_free(errorMessage);
        }

        if (error) {
            *error = MakeError(ZSignErrorSignFailed, message ?: @"签名失败", nil);
        }
        return NO;
    }

    return YES;
}

@end
