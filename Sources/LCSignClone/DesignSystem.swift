import LCSignCore
import SwiftUI

// MARK: - 颜色令牌
//
// 之前每个界面都是裸 Form / List，颜色直接用 .red / .green / .secondary，
// 结果就是「能跑但很丑」：状态色不成体系、间距随手写、层级全靠系统默认。
// 这里把颜色、间距、圆角、字号全部收成令牌，界面只引用令牌。

extension Color {

    /// 用 16 进制字面量构造颜色，并区分深浅色。
    ///
    /// 不用 `Color(red:green:blue:)` 逐处写：那种写法在深色模式下要么
    /// 对比度不够（暗色上压暗色），要么刺眼，而且改一次要翻遍所有文件。
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(rgb: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

extension UIColor {

    /// 0xRRGGBB
    convenience init(rgb: UInt32) {
        self.init(
            red: CGFloat((rgb >> 16) & 0xFF) / 255,
            green: CGFloat((rgb >> 8) & 0xFF) / 255,
            blue: CGFloat(rgb & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// 品牌与语义色。所有界面一律从这里取色。
enum Brand {

    /// 主色：靛蓝。签名工具是「精密仪器」的定位，冷色比暖色更贴。
    static let accent     = Color(light: 0x4F46E5, dark: 0x818CF8)
    static let accentDeep = Color(light: 0x312E81, dark: 0x4338CA)
    static let accentSoft = Color(light: 0xEEF2FF, dark: 0x1E1B4B)

    static let success    = Color(light: 0x047857, dark: 0x34D399)
    static let warning    = Color(light: 0xB45309, dark: 0xFBBF24)
    static let danger     = Color(light: 0xB91C1C, dark: 0xF87171)

    /// 卡片表面 / 页面底色 / 分隔线
    static let surface    = Color(uiColor: .secondarySystemGroupedBackground)
    static let canvas     = Color(uiColor: .systemGroupedBackground)
    static let sunken     = Color(uiColor: .tertiarySystemGroupedBackground)
    static let hairline   = Color(uiColor: .separator).opacity(0.45)

    /// 主视觉渐变
    static var heroGradient: LinearGradient {
        LinearGradient(colors: [accentDeep, accent],
                       startPoint: .topLeading,
                       endPoint: .bottomTrailing)
    }

    /// 状态对应的语义色
    static func tint(for level: SigningCertificate.ExpiryLevel) -> Color {
        switch level {
        case .healthy:  return success
        case .warning:  return warning
        case .critical, .expired: return danger
        }
    }
}

// MARK: - 尺寸令牌

enum Metric {

    /// 间距阶梯。只允许用这几个值，避免出现 7 / 11 / 13 这种随手写的数。
    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
    }

    enum Radius {
        static let small: CGFloat = 10
        static let card: CGFloat = 18
        static let hero: CGFloat = 24
    }

    /// 页面左右留白
    static let pageMargin: CGFloat = 16
}

// MARK: - 字号令牌

enum Typo {

    static let wordmark = Font.system(size: 19, weight: .bold, design: .rounded)
    static let heroTitle = Font.system(size: 26, weight: .bold, design: .rounded)
    static let sectionTitle = Font.system(size: 13, weight: .semibold)
    static let cardTitle = Font.system(size: 16, weight: .semibold)
    static let body = Font.system(size: 15)
    static let caption = Font.system(size: 13)
    static let micro = Font.system(size: 11, weight: .semibold)

    /// 标识符（Team ID、Bundle ID、路径）用等宽，方便逐字符核对
    static func identifier(_ size: CGFloat = 13) -> Font {
        .system(size: size, design: .monospaced)
    }
}

// MARK: - 卡片容器

/// 统一圆角 + 细边框 + 极浅投影的卡片。
///
/// 用 ScrollView + 卡片替代 List：List 的 insetGrouped 外观在深色模式下
/// 会把每一节切成灰底块，层与层之间没有呼吸感 —— 这正是「丑」的来源之一。
struct Card<Content: View>: View {

    var padding: CGFloat = Metric.Space.l
    var radius: CGFloat = Metric.Radius.card
    var fill: Color = Brand.surface
    let content: () -> Content

    /// 显式写 init 而不是依赖逐成员构造器：`@ViewBuilder` 能不能从存储属性
    /// 传递到逐成员构造器上，各版本编译器表现不一致；显式声明一次省得赌。
    init(padding: CGFloat = Metric.Space.l,
         radius: CGFloat = Metric.Radius.card,
         fill: Color = Brand.surface,
         @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding
        self.radius = radius
        self.fill = fill
        self.content = content
    }

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Brand.hairline, lineWidth: 0.5)
            )
            .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)
    }
}

/// 分节标题。放在卡片外面，给整页建立层级。
struct SectionHeader: View {

    let title: String
    var trailing: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(Typo.sectionTitle)
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(Typo.micro)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, Metric.Space.xs)
    }
}

// MARK: - 图标徽章

/// 圆角方块里放一个 SF Symbol，用于卡片左侧建立视觉锚点。
struct IconBadge: View {

    let symbol: String
    var tint: Color = Brand.accent
    var size: CGFloat = 42

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundColor(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14))
            .clipShape(RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
    }
}

// MARK: - 状态胶囊

struct StatusPill: View {

    let text: String
    var tint: Color = Brand.accent
    var symbol: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
            }
            Text(text)
                .font(Typo.micro)
        }
        .foregroundColor(tint)
        .padding(.horizontal, Metric.Space.s)
        .padding(.vertical, 4)
        .background(tint.opacity(0.14))
        .clipShape(Capsule())
    }
}

// MARK: - 进度条

/// 细胶囊进度条。比 `ProgressView(.linear)` 更可控：能上渐变、能配状态色。
struct Meter: View {

    var value: Double
    var tint: Color = Brand.accent
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Brand.hairline)
                Capsule()
                    .fill(LinearGradient(colors: [tint.opacity(0.65), tint],
                                         startPoint: .leading,
                                         endPoint: .trailing))
                    .frame(width: max(height,
                                      geometry.size.width * CGFloat(clamped)))
            }
        }
        .frame(height: height)
    }

    private var clamped: Double { min(max(value, 0), 1) }
}

// MARK: - 键值行

struct InfoRow: View {

    let title: String
    let value: String
    var monospaced: Bool = false
    var selectable: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(Typo.micro)
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            Group {
                if selectable {
                    Text(value).textSelection(.enabled)
                } else {
                    Text(value)
                }
            }
            .font(monospaced ? Typo.identifier(12) : Typo.body)
            .foregroundColor(.primary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 按钮样式

/// 主操作按钮。禁用态必须显式处理 —— 直接给白字配灰底会糊成一团。
struct PrimaryActionStyle: ButtonStyle {

    var tint: Color = Brand.accent
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, tint: tint, compact: compact)
    }

    /// 用 `ButtonStyleConfiguration` 而不是裸写 `Configuration`：
    /// 关联类型在嵌套类型里是否可见，取决于编译器的名字查找顺序，
    /// 写全名就没有这个不确定性。
    private struct StyledLabel: View {

        let configuration: ButtonStyleConfiguration
        let tint: Color
        let compact: Bool

        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            configuration.label
                .font(.system(size: compact ? 14 : 16, weight: .semibold))
                .foregroundColor(isEnabled ? .white : Color.secondary)
                .frame(maxWidth: compact ? nil : .infinity)
                .padding(.horizontal, compact ? Metric.Space.m : 0)
                .padding(.vertical, compact ? 9 : 15)
                .background(background)
                .clipShape(RoundedRectangle(cornerRadius: compact ? 10 : 14,
                                            style: .continuous))
                .opacity(configuration.isPressed ? 0.86 : 1)
                .scaleEffect(configuration.isPressed && isEnabled ? 0.985 : 1)
                .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
        }

        private var background: some View {
            Group {
                if isEnabled {
                    LinearGradient(colors: [tint, tint.opacity(0.86)],
                                   startPoint: .topLeading,
                                   endPoint: .bottomTrailing)
                } else {
                    Color(uiColor: .tertiarySystemFill)
                }
            }
        }
    }
}

/// 次级按钮：描边、无填充
struct GhostActionStyle: ButtonStyle {

    var tint: Color = Brand.accent
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 13 : 15, weight: .semibold))
            .foregroundColor(tint)
            .padding(.horizontal, compact ? Metric.Space.m : Metric.Space.l)
            .padding(.vertical, compact ? 8 : 12)
            .background(tint.opacity(configuration.isPressed ? 0.16 : 0.09))
            .clipShape(RoundedRectangle(cornerRadius: compact ? 10 : 13,
                                        style: .continuous))
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - 提示条

/// 内联提示。用来替代「弹窗报错」—— 错误信息贴在出错的那张卡上，
/// 比弹一个需要点掉的对话框有用得多。
struct NoticeBar: View {

    enum Level {
        case info, warning, danger, success

        var tint: Color {
            switch self {
            case .info:    return Brand.accent
            case .warning: return Brand.warning
            case .danger:  return Brand.danger
            case .success: return Brand.success
            }
        }

        var symbol: String {
            switch self {
            case .info:    return "info.circle.fill"
            case .warning: return "exclamationmark.triangle.fill"
            case .danger:  return "xmark.octagon.fill"
            case .success: return "checkmark.circle.fill"
            }
        }
    }

    let level: Level
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: Metric.Space.s) {
            Image(systemName: level.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(level.tint)
            Text(text)
                .font(Typo.caption)
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Metric.Space.m)
        .background(level.tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: Metric.Radius.small,
                                    style: .continuous))
    }
}

// MARK: - 空状态

/// 统一的空状态：柔和圆底 + 图标 + 标题 + 说明 + 可选操作。
/// 之前每个界面各写一版，字号和留白都不一样，这是「不像个成品」的主因。
struct EmptyState<Actions: View>: View {

    let symbol: String
    let title: String
    let message: String
    var tint: Color = Brand.accent
    let actions: () -> Actions

    init(symbol: String,
         title: String,
         message: String,
         tint: Color = Brand.accent,
         @ViewBuilder actions: @escaping () -> Actions) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.tint = tint
        self.actions = actions
    }

    var body: some View {
        VStack(spacing: Metric.Space.l) {
            ZStack {
                Circle()
                    .fill(tint.opacity(0.10))
                    .frame(width: 92, height: 92)
                Image(systemName: symbol)
                    .font(.system(size: 38, weight: .light))
                    .foregroundColor(tint)
            }

            VStack(spacing: Metric.Space.s) {
                Text(title)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                Text(message)
                    .font(Typo.caption)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            actions()
                .padding(.top, Metric.Space.xs)
        }
        .padding(.horizontal, Metric.Space.xl)
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metric.Space.xxl)
    }
}

extension EmptyState where Actions == EmptyView {
    init(symbol: String, title: String, message: String, tint: Color = Brand.accent) {
        self.init(symbol: symbol, title: title, message: message, tint: tint) {
            EmptyView()
        }
    }
}

// MARK: - 统计

/// 把字节数格式化成人类可读的形式
func formattedBytes(_ count: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
}

/// 把秒数格式化成「3.4 秒」/「1 分 12 秒」
func formattedDuration(_ seconds: TimeInterval) -> String {
    if seconds < 60 {
        return String(format: "%.1f 秒", seconds)
    }
    let total = Int(seconds.rounded())
    return "\(total / 60) 分 \(total % 60) 秒"
}
