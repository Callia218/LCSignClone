import XCTest
import LCSignCore

/// 证书模型的有效期分级与可用性判断。
///
/// `isUsable` 直接决定签名按钮能不能点，判错的后果是要么白签一堆装不上的包，
/// 要么把本来能用的证书挡住。所以每个分支都单独钉一条。
final class SigningCertificateTests: XCTestCase {

    private func makeCertificate(
        notAfterDays: Double,
        teamID: String = "ABCDE12345",
        provisionTeamID: String? = "ABCDE12345",
        hasProvision: Bool = true
    ) -> SigningCertificate {

        let provision = hasProvision
            ? SigningCertificate.ProvisionSummary(
                name: "测试描述文件",
                teamID: provisionTeamID ?? teamID,
                applicationIdentifier: "\(provisionTeamID ?? teamID).com.example.app",
                expirationDate: Date().addingTimeInterval(86_400 * 90),
                provisionedDeviceCount: 3
              )
            : nil

        return SigningCertificate(
            displayName: "测试证书",
            teamID: teamID,
            commonName: "iPhone Developer: Test (ABCD1234)",
            notBefore: Date().addingTimeInterval(-86_400 * 30),
            notAfter: Date().addingTimeInterval(86_400 * notAfterDays),
            p12RelativePath: "x/identity.p12",
            provisionRelativePath: hasProvision ? "x/profile.mobileprovision" : nil,
            provision: provision
        )
    }

    // MARK: - 有效期分级

    func testExpiryLevelBoundaries() {
        // 多给半天余量：daysRemaining 走的是 Calendar 的整日差，
        // 正好卡在整数天边界上会随两次 Date() 之间的真实耗时抖动。
        func level(_ days: Double) -> SigningCertificate.ExpiryLevel {
            makeCertificate(notAfterDays: days).expiryLevel
        }

        XCTAssertEqual(level(-1), .expired)
        XCTAssertEqual(level(0.5), .critical)
        XCTAssertEqual(level(6.5), .critical)
        XCTAssertEqual(level(10.5), .warning)
        XCTAssertEqual(level(29.5), .warning)
        XCTAssertEqual(level(60), .healthy)
    }

    func testExpiredCertificateIsNotUsable() {
        let certificate = makeCertificate(notAfterDays: -1)

        XCTAssertTrue(certificate.isExpired)
        XCTAssertEqual(certificate.daysRemaining, 0)
        XCTAssertFalse(certificate.isUsable)
        XCTAssertEqual(certificate.expiryDescription, "已过期")
    }

    // MARK: - 配对与可用性

    func testUsableWhenEverythingLinesUp() {
        let certificate = makeCertificate(notAfterDays: 200)

        XCTAssertFalse(certificate.isExpired)
        XCTAssertTrue(certificate.isPaired)
        XCTAssertTrue(certificate.isUsable)
    }

    func testMissingProvisionMakesCertificateUnusable() {
        // 只有 p12 是签不出可安装的包的 —— zsign 非 adhoc 模式必须要描述文件
        let certificate = makeCertificate(notAfterDays: 200, hasProvision: false)

        XCTAssertNil(certificate.provisionRelativePath)
        XCTAssertFalse(certificate.isPaired)
        XCTAssertFalse(certificate.isUsable)
    }

    func testTeamMismatchMakesCertificateUnusable() {
        let certificate = makeCertificate(
            notAfterDays: 200,
            teamID: "ABCDE12345",
            provisionTeamID: "ZZZZZ99999"
        )

        XCTAssertFalse(certificate.isPaired)
        XCTAssertFalse(certificate.isUsable)
        // 证书本身没过期，过期描述不该被配对问题带偏
        XCTAssertFalse(certificate.isExpired)
    }
}
