import Foundation

/// 签名流程中可能出现的错误。
///
/// 每一条都对应一个具体的排查动作 —— 重签名失败的原因高度集中，
/// 与其抛一句「签名失败」，不如直接告诉用户该去看哪里。
public enum SigningError: LocalizedError, Equatable {

    // 输入问题
    case inputNotFound(URL)
    case p12Unreadable(String)
    case profileUnreadable(String)
    /// 归档打不开（不是合法 zip / 文件被截断 / 权限问题）
    case archiveUnreadable(String)
    /// 归档能打开，但里面找不到可用的 .app。关联值是诊断细节
    /// （例如「Payload 里实际有什么」），排查时比一句「不是有效归档」有用得多。
    case noAppBundleInArchive(String)
    case executableMissing(String)

    // 证书与描述文件不匹配
    case teamIDMismatch(certificate: String, profile: String)
    case bundleIDNotCovered(bundleID: String, profileAppID: String)
    case profileExpired(Date)
    case profileDeviceNotProvisioned

    // 签名与打包
    case entitlementsNotAuthorized([String])
    case engineFailed(String)
    case packagingFailed(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .inputNotFound(let url):
            return "找不到文件：\(url.lastPathComponent)"

        case .p12Unreadable(let reason):
            return "证书无法读取：\(reason)"

        case .profileUnreadable(let reason):
            return "描述文件无法读取：\(reason)"

        case .archiveUnreadable(let reason):
            return "打不开这个 IPA 归档：\(reason)"

        case .noAppBundleInArchive(let detail):
            return "IPA 里没有可用的 Payload/*.app。\(detail)"

        case .executableMissing(let name):
            return "App 目录里找不到可执行文件 \(name)，包可能已损坏。"

        case .teamIDMismatch(let cert, let profile):
            return "证书与描述文件的 Team ID 不一致（证书 \(cert) / 描述文件 \(profile)）。"

        case .bundleIDNotCovered(let bundleID, let appID):
            return "描述文件的 App ID（\(appID)）无法覆盖目标 Bundle ID（\(bundleID)）。"

        case .profileExpired(let date):
            let f = DateFormatter()
            f.dateStyle = .medium
            return "描述文件已于 \(f.string(from: date)) 过期。"

        case .profileDeviceNotProvisioned:
            return "本机 UDID 不在描述文件的设备白名单里。"

        case .entitlementsNotAuthorized(let keys):
            return "以下权限超出描述文件授权范围：\(keys.joined(separator: "、"))"

        case .engineFailed(let message):
            return "签名引擎报错：\(message)"

        case .packagingFailed(let message):
            return "重新打包失败：\(message)"

        case .cancelled:
            return "操作已取消。"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .inputNotFound:
            return "确认文件没有被移动或删除，必要时重新选择。"

        case .p12Unreadable:
            return "确认 p12 导出密码正确。可用命令验证：\n"
                 + "openssl pkcs12 -in cert.p12 -noout -passin pass:你的密码"

        case .profileUnreadable:
            return "确认选的是 .mobileprovision 描述文件，而不是 .p12 证书。\n"
                 + "可用命令查看内容：security cms -D -i profile.mobileprovision"

        case .archiveUnreadable:
            return "确认文件没有被截断，且确实是一个 zip 归档。"
                 + "可以先用命令检查：unzip -l 你的文件.ipa"

        case .noAppBundleInArchive:
            return "换一个来源可靠的 IPA 重试。若这是本机刚签出来的产物，"
                 + "请把上面这段实际内容一并反馈，那是定位问题的关键线索。"

        case .executableMissing:
            return "重新下载原始 IPA，当前文件可能不完整。"

        case .teamIDMismatch:
            return "去 developer.apple.com 重新生成与证书同属一个 Team 的描述文件。"

        case .bundleIDNotCovered:
            return "两个办法：1) 把目标 Bundle ID 改成描述文件覆盖范围内的值；"
                 + "2) 在开发者后台为这个 Bundle ID 新建描述文件。"

        case .profileExpired:
            return "重新下载描述文件。个人开发者账号的描述文件最长一年，免费账号只有 7 天。"

        case .profileDeviceNotProvisioned:
            return "在开发者后台 Devices 里添加本机 UDID，然后重新生成描述文件。"

        case .entitlementsNotAuthorized:
            return "把超范围的权限删掉，或换一个授权更宽的描述文件。"
                 + "这是「签完能装、一打开就闪退」的头号原因。"

        case .engineFailed, .packagingFailed:
            return "查看日志里的详细输出，通常是证书、描述文件或磁盘空间的问题。"

        case .cancelled:
            return nil
        }
    }
}
