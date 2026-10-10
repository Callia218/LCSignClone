#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

FOUNDATION_EXPORT NSString * const ZSignErrorDomain;

typedef NS_ERROR_ENUM(ZSignErrorDomain, ZSignErrorCode) {
    ZSignErrorFileNotFound   = 1,
    ZSignErrorBadCredentials = 2,
    ZSignErrorInitFailed     = 3,
    ZSignErrorSignFailed     = 4,
};

/// zsign C++ 引擎的 Objective-C 封装。
///
/// 只做一件事：把已经解包好的 .app 目录签掉。
/// 解包、打包、校验描述文件等逻辑都在 Swift 侧，这里保持最薄。
@interface ZSignBridge : NSObject

/// 对已解包的 .app 目录执行签名。
///
/// @param appPath          已解包的 .app 目录路径
/// @param p12Path          证书 p12 文件路径
/// @param p12Password      p12 导出密码，无密码传空串
/// @param provisionPath    描述文件路径（强烈建议提供，缺失会导致装不上）
/// @param entitlementsPath 自定义 entitlements plist，传 nil 则从描述文件读取
/// @param bundleId         改写 Bundle ID，传 nil 保持原值
/// @param bundleVersion    改写版本号，传 nil 保持原值
/// @param displayName      改写显示名，传 nil 保持原值
/// @param iconFile         替换图标 png，传 nil 保持原值
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
                error:(NSError *_Nullable *_Nullable)error;

@end

NS_ASSUME_NONNULL_END
