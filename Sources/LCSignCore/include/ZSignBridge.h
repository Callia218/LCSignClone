#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const ZSignErrorDomain;

typedef NS_ERROR_ENUM(ZSignErrorDomain, ZSignErrorCode) {
    ZSignErrorFileNotFound   = 1,
    ZSignErrorBadCredentials = 2,
    ZSignErrorInitFailed     = 3,
    ZSignErrorSignFailed     = 4,
};

/// p12 证书里我们关心的那几个字段。
///
/// 为什么要自己解析：iOS SDK 里没有 `SecCertificateCopyValues`，
/// 也没有 `kSecOIDX509V1Validity*` / `kSecPropertyKeyValue` 这些常量
/// （全是 macOS 独有的），走 Security.framework 读不到 Team ID 和有效期。
/// 底层由 zsign 已经链进来的 OpenSSL 完成解析。
@interface ZSignP12Info : NSObject

/// 证书 subject 的 CN，形如 "iPhone Developer: Foo Bar (ABCD1234)"
@property (nonatomic, copy, readonly) NSString *commonName;
/// 证书 subject 的 OU，就是 Apple Team ID
@property (nonatomic, copy, readonly) NSString *teamID;
@property (nonatomic, strong, readonly) NSDate *notBefore;
@property (nonatomic, strong, readonly) NSDate *notAfter;

@end

/// zsign C++ 引擎的 Objective-C 封装。
///
/// 只做两件事：把已经解包好的 .app 目录签掉，以及读 p12 的元信息。
/// 解包、打包、校验描述文件等逻辑都在 Swift 侧，这里保持最薄。
@interface ZSignBridge : NSObject

/// 对已解包的 .app 目录执行签名。
///
/// @param appPath          已解包的 .app 目录路径（不是 IPA）
/// @param p12Path          证书 p12 文件路径
/// @param p12Password      p12 导出密码，无密码传空串
/// @param provisionPath    描述文件路径。**必需** —— zsign 要从里面读 TeamId
/// @param entitlementsPath 自定义 entitlements plist，传 nil 则从描述文件读取
/// @param bundleId         改写 Bundle ID，传 nil 保持原值
/// @param bundleVersion    改写版本号，传 nil 保持原值
/// @param displayName      改写显示名，传 nil 保持原值
/// @param iconFile         预留参数。当前 shim 尚未接入（zsign 需要把图标文件
///                         先放进 .app 目录再通过 ZBundle 成员设置），传 nil
/// @param dylibPaths       需要注入的 dylib 路径列表
+ (BOOL)signAppAtPath:(NSString *)appPath
              p12Path:(NSString *)p12Path
          p12Password:(NSString *)p12Password
        provisionPath:(nullable NSString *)provisionPath
     entitlementsPath:(nullable NSString *)entitlementsPath
             bundleId:(nullable NSString *)bundleId
        bundleVersion:(nullable NSString *)bundleVersion
          displayName:(nullable NSString *)displayName
             iconFile:(nullable NSString *)iconFile
           dylibPaths:(nullable NSArray<NSString *> *)dylibPaths
                error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(signApp(atPath:p12Path:p12Password:provisionPath:entitlementsPath:bundleId:bundleVersion:displayName:iconFile:dylibPaths:));

/// 读取 p12 的证书信息（CN / Team ID / 有效期）。
///
/// 失败时返回 nil 并通过 `error` 说明原因（多半是密码不对）。
+ (nullable ZSignP12Info *)inspectP12AtPath:(NSString *)p12Path
                                   password:(nullable NSString *)password
                                      error:(NSError *_Nullable *_Nullable)error
    NS_SWIFT_NAME(inspectP12(path:password:));

@end

NS_ASSUME_NONNULL_END
