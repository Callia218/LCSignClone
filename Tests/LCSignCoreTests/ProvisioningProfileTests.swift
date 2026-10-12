import XCTest
import LCSignCore

/// 描述文件解析与授权比对。
///
/// 这两块逻辑决定了「签出来的包能不能装」和「装上了会不会一开就闪退」，
/// 而且都是纯字符串/字典处理 —— 恰恰是最容易写出边界 bug 的地方，
/// 所以每一条边界都在这里钉死。
final class ProvisioningProfileTests: XCTestCase {

    // MARK: - App ID 覆盖范围

    func testExactAppIDMatchesOnlyItself() throws {
        let profile = try makeProvisioningProfile(
            applicationIdentifier: "ABCDE12345.com.example.app"
        )

        XCTAssertTrue(profile.covers(bundleID: "com.example.app"))
        XCTAssertFalse(profile.covers(bundleID: "com.example.other"))
        XCTAssertFalse(profile.covers(bundleID: "com.example"))
        XCTAssertFalse(profile.isWildcard)
        XCTAssertEqual(profile.appIDPattern, "com.example.app")
    }

    func testPrefixWildcardCoversSubdomains() throws {
        let profile = try makeProvisioningProfile(
            applicationIdentifier: "ABCDE12345.com.example.*"
        )

        XCTAssertTrue(profile.isWildcard)
        XCTAssertEqual(profile.appIDPattern, "com.example.*")

        XCTAssertTrue(profile.covers(bundleID: "com.example.app"))
        XCTAssertTrue(profile.covers(bundleID: "com.example.a.b"))
        // 通配符落在 `.*` 上，裸前缀本身也算被覆盖
        XCTAssertTrue(profile.covers(bundleID: "com.example"))
        // 但不能越界到 com.exampleX
        XCTAssertFalse(profile.covers(bundleID: "com.exampleX"))
        XCTAssertFalse(profile.covers(bundleID: "com.other.app"))
    }

    func testGlobalWildcardCoversEverything() throws {
        let profile = try makeProvisioningProfile(applicationIdentifier: "ABCDE12345.*")

        XCTAssertTrue(profile.isWildcard)
        XCTAssertTrue(profile.covers(bundleID: "com.example.app"))
        XCTAssertTrue(profile.covers(bundleID: "com.anything.at.all"))
    }

    // MARK: - entitlements 授权比对

    func testMissingEntitlementIsFlagged() throws {
        let profile = try makeProvisioningProfile(
            applicationIdentifier: "ABCDE12345.com.example.app",
            entitlements: ["aps-environment": "development"]
        )

        XCTAssertEqual(
            profile.unauthorizedEntitlementKeys(in: ["aps-environment": "production"]),
            ["aps-environment"]
        )
        XCTAssertTrue(
            profile.unauthorizedEntitlementKeys(in: ["aps-environment": "development"]).isEmpty
        )
        XCTAssertEqual(
            profile.unauthorizedEntitlementKeys(in: ["com.apple.developer.healthkit": true]),
            ["com.apple.developer.healthkit"]
        )
    }

    func testIdentityScopedEntitlementsAreExempt() throws {
        // 这几个键天生绑定签名身份，zsign 会按目标描述文件重写它们。
        // 拿源 App 里带过来的旧 Team 值去比，只要换了 Team 就会误杀合法请求。
        let profile = try makeProvisioningProfile(
            applicationIdentifier: "ABCDE12345.com.example.app",
            entitlements: ["aps-environment": "development"]
        )

        let target: [String: Any] = [
            "application-identifier": "ZZZZZ99999.com.example.app",
            "com.apple.developer.team-identifier": "ZZZZZ99999",
            "get-task-allow": true,
            "keychain-access-groups": ["ZZZZZ99999.*"]
        ]

        XCTAssertTrue(profile.unauthorizedEntitlementKeys(in: target).isEmpty)
    }

    func testArrayEntitlementUsesWildcardSubset() throws {
        let key = "com.apple.developer.icloud-container-identifiers"
        let profile = try makeProvisioningProfile(
            applicationIdentifier: "ABCDE12345.com.example.app",
            entitlements: [key: ["iCloud.com.example.*"]]
        )

        XCTAssertTrue(
            profile.unauthorizedEntitlementKeys(in: [key: ["iCloud.com.example.app"]]).isEmpty
        )
        XCTAssertTrue(
            profile.unauthorizedEntitlementKeys(
                in: [key: ["iCloud.com.example.a", "iCloud.com.example.b"]]
            ).isEmpty
        )
        XCTAssertEqual(
            profile.unauthorizedEntitlementKeys(in: [key: ["iCloud.com.other.app"]]),
            [key]
        )
        // 子集判断：只要有一个元素越界，整个键就算越界
        XCTAssertEqual(
            profile.unauthorizedEntitlementKeys(
                in: [key: ["iCloud.com.example.a", "iCloud.com.other.b"]]
            ),
            [key]
        )
    }

    func testStringEntitlementRequiresExactOrWildcardMatch() throws {
        let key = "com.apple.developer.associated-domains"
        let profile = try makeProvisioningProfile(
            applicationIdentifier: "ABCDE12345.com.example.app",
            entitlements: [key: ["applinks:example.com", "applinks:*.example.org"]]
        )

        XCTAssertTrue(
            profile.unauthorizedEntitlementKeys(in: [key: ["applinks:example.com"]]).isEmpty
        )
        XCTAssertTrue(
            profile.unauthorizedEntitlementKeys(in: [key: ["applinks:www.example.org"]]).isEmpty
        )
        XCTAssertEqual(
            profile.unauthorizedEntitlementKeys(in: [key: ["applinks:evil.com"]]),
            [key]
        )
    }

    func testTrailingWildcardAlsoCoversBarePrefix() throws {
        // Apple 对 `X.*` 的定义是「覆盖 X 本身以及 X 下面的一切」，
        // entitlements 的通配写法沿用同一套规则。按严格 glob 语义会误判成越权。
        let key = "com.apple.developer.icloud-container-identifiers"
        let profile = try makeProvisioningProfile(
            applicationIdentifier: "ABCDE12345.com.example.app",
            entitlements: [key: ["iCloud.com.example.*"]]
        )

        XCTAssertTrue(profile.unauthorizedEntitlementKeys(in: [key: ["iCloud.com.example"]]).isEmpty)
        XCTAssertTrue(profile.unauthorizedEntitlementKeys(in: [key: ["iCloud.com.example.a.b"]]).isEmpty)
        XCTAssertEqual(
            profile.unauthorizedEntitlementKeys(in: [key: ["iCloud.com.exampleX"]]),
            [key]
        )
    }

    func testNestedDictionaryEntitlement() throws {
        let key = "com.apple.developer.some-dictionary"
        let profile = try makeProvisioningProfile(
            applicationIdentifier: "ABCDE12345.com.example.app",
            entitlements: [key: ["enabled": true, "region": "cn"]]
        )

        XCTAssertTrue(
            profile.unauthorizedEntitlementKeys(in: [key: ["enabled": true]]).isEmpty
        )
        // 描述文件里没有的嵌套键，不能算通过
        XCTAssertEqual(
            profile.unauthorizedEntitlementKeys(in: [key: ["missing": true]]),
            [key]
        )
        XCTAssertEqual(
            profile.unauthorizedEntitlementKeys(in: [key: ["region": "us"]]),
            [key]
        )
    }

    // MARK: - 基本字段与过期

    func testParsesMetadata() throws {
        let expiry = Date().addingTimeInterval(86_400 * 30)
        let profile = try makeProvisioningProfile(
            applicationIdentifier: "ABCDE12345.com.example.app",
            expirationDate: expiry,
            teamID: "TEAM123456",
            name: "我的描述文件"
        )

        XCTAssertEqual(profile.name, "我的描述文件")
        XCTAssertEqual(profile.teamID, "TEAM123456")
        XCTAssertEqual(profile.platforms, ["iOS"])
        XCTAssertEqual(profile.expirationDate.timeIntervalSince1970,
                       expiry.timeIntervalSince1970,
                       accuracy: 1)
        XCTAssertFalse(profile.isExpired)
        XCTAssertFalse(profile.uuid.isEmpty)
    }

    func testExpiredProfileIsDetected() throws {
        let profile = try makeProvisioningProfile(
            applicationIdentifier: "ABCDE12345.com.example.app",
            expirationDate: Date().addingTimeInterval(-3600)
        )

        XCTAssertTrue(profile.isExpired)
        XCTAssertEqual(profile.daysRemaining, 0)
    }

    func testRejectsNonProfileData() {
        XCTAssertThrowsError(try ProvisioningProfile.parse(Data("not a plist at all".utf8)))
    }
}
