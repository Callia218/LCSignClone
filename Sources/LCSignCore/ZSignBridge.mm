#import "ZSignBridge.h"

#include "zsign_shim.h"

#include <cstdlib>

NSString * const ZSignErrorDomain = @"com.example.lcsigncore.zsign";

static NSError *MakeError(ZSignErrorCode code, NSString *message, NSString *suggestion) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[NSLocalizedDescriptionKey] = message ?: @"未知错误";
    if (suggestion.length > 0) {
        info[NSLocalizedRecoverySuggestionErrorKey] = suggestion;
    }
    return [NSError errorWithDomain:ZSignErrorDomain code:code userInfo:info];
}

#pragma mark - ZSignP12Info

@interface ZSignP12Info ()
@property (nonatomic, copy, readwrite) NSString *commonName;
@property (nonatomic, copy, readwrite) NSString *teamID;
@property (nonatomic, strong, readwrite) NSDate *notBefore;
@property (nonatomic, strong, readwrite) NSDate *notAfter;
@end

@implementation ZSignP12Info
@end

#pragma mark - ZSignBridge

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

+ (nullable ZSignP12Info *)inspectP12AtPath:(NSString *)p12Path
                                   password:(NSString *)password
                                      error:(NSError **)error
{
    NSFileManager *fm = NSFileManager.defaultManager;

    if (p12Path.length == 0 || ![fm fileExistsAtPath:p12Path]) {
        if (error) {
            *error = MakeError(ZSignErrorFileNotFound,
                               @"找不到 p12 证书文件。",
                               p12Path.length > 0
                                   ? [NSString stringWithFormat:@"路径：%@", p12Path]
                                   : nil);
        }
        return nil;
    }

    zsign_shim_p12_info info;
    char *errorMessage = NULL;

    const int result = zsign_shim_inspect_p12(
        p12Path.UTF8String,
        (password ?: @"").UTF8String,
        &info,
        &errorMessage
    );

    if (result != 1) {
        NSString *message = (errorMessage != NULL)
            ? [NSString stringWithUTF8String:errorMessage]
            : @"p12 解析失败。";

        if (errorMessage != NULL) {
            zsign_shim_free(errorMessage);
        }

        if (error) {
            *error = MakeError(ZSignErrorBadCredentials,
                               message ?: @"p12 解析失败。",
                               @"确认导出密码正确。可用命令验证：\n"
                               @"openssl pkcs12 -in cert.p12 -noout -passin pass:你的密码");
        }
        return nil;
    }

    ZSignP12Info *parsed = [[ZSignP12Info alloc] init];

    if (info.common_name != NULL) {
        parsed.commonName = [NSString stringWithUTF8String:info.common_name] ?: @"";
    } else {
        parsed.commonName = @"";
    }

    if (info.team_id != NULL) {
        parsed.teamID = [NSString stringWithUTF8String:info.team_id] ?: @"";
    } else {
        parsed.teamID = @"";
    }

    parsed.notBefore = (info.not_before > 0.0)
        ? [NSDate dateWithTimeIntervalSince1970:info.not_before]
        : NSDate.distantPast;
    parsed.notAfter = (info.not_after > 0.0)
        ? [NSDate dateWithTimeIntervalSince1970:info.not_after]
        : NSDate.distantPast;

    // 结构体里的字符串由 shim 分配，读完必须还回去
    zsign_shim_free_p12_info(&info);

    return parsed;
}

@end
