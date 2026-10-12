import XCTest
import LCSignCore

/// 引擎自检的集成用例。
///
/// 这条用例跑的是**同一段** `EngineSelfTest.run()`，也就是 App 里诊断页
/// 按钮触发的那段代码。它会在模拟器上真跑一遍：
///
///   构造合成 .app（含真实 Mach-O）→ 打包 IPA → 解包 → ad-hoc 签名 → 校验产物
///
/// 意义在于：这条链路里任何一环坏了（zsign 没链上、静态库架构不对、
/// ZIPFoundation 用法变了、沙盒临时目录写不了），CI 就会红，
/// 而不是等到装到真机上点一下才发现。
final class EngineSelfTestTests: XCTestCase {

    func testEngineSelfTestPasses() {
        let report = EngineSelfTest.run()

        XCTAssertFalse(report.steps.isEmpty, "自检一步都没跑")

        let titles = report.steps.map(\.title)

        // 至少要走到最后两步，否则说明前面某步提前返回了
        XCTAssertTrue(
            titles.contains("调用签名引擎（ad-hoc）"),
            "自检没走到签名步骤，实际步骤：\(titles)\n\(describe(report))"
        )
        XCTAssertTrue(
            titles.contains("校验签名产物"),
            "自检没走到产物校验，实际步骤：\(titles)\n\(describe(report))"
        )

        XCTAssertTrue(report.isHealthy, "引擎自检未通过：\n\(describe(report))")
        XCTAssertEqual(report.failureCount, 0)
    }

    private func describe(_ report: EngineSelfTest.Report) -> String {
        report.steps.map { step in
            let mark: String
            switch step.outcome {
            case .passed:  mark = "✓"
            case .failed:  mark = "✗"
            case .skipped: mark = "-"
            }
            return "  \(mark) \(step.title)：\(step.outcome.text)（\(step.detail)）"
        }.joined(separator: "\n")
    }
}
