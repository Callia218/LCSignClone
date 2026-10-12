import LCSignCore
import SwiftUI
import UniformTypeIdentifiers

/// 重签名页。
///
/// 结构上刻意做成「选择 → 校验 → 执行」三段式，而不是把所有字段平铺在一个 Form 里：
/// 用户在这个页面只需要回答两个问题（签哪个包、用哪张证书），
/// 其余（Bundle ID 改写、显示名称）属于少数场景，折叠起来不抢注意力。
struct SignSheet: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedIPA: URL?
    @State private var selectedCertificate: SigningCertificate?
    @State private var bundleID = ""
    @State private var displayName = ""

    @State private var showingIPAPicker = false
    @State private var showingAdvanced = false
    @State private var isSigning = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: Metric.Space.l) {
                    ipaSection
                    certificateSection
                    advancedSection
                    blockingNotice
                }
                .padding(.horizontal, Metric.pageMargin)
                .padding(.bottom, Metric.Space.xxl)
            }
            .background(Brand.canvas.ignoresSafeArea())
            .navigationTitle("重签名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSigning)
                }
            }
            .safeAreaInset(edge: .bottom) { actionBar }
            .fileImporter(
                isPresented: $showingIPAPicker,
                allowedContentTypes: [.ipaArchive],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    selectedIPA = url
                }
            }
            .onAppear(perform: prepareSelection)
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 待签名的包

    private var ipaSection: some View {
        VStack(alignment: .leading, spacing: Metric.Space.s) {
            SectionHeader(title: "待签名的应用")

            Button {
                showingIPAPicker = true
            } label: {
                Card(padding: Metric.Space.l) {
                    if let selectedIPA {
                        selectedFile(selectedIPA)
                    } else {
                        emptyFileSlot
                    }
                }
                .overlay(
                    RoundedRectangle(cornerRadius: Metric.Radius.card, style: .continuous)
                        .strokeBorder(
                            selectedIPA == nil ? Brand.accent.opacity(0.45) : Color.clear,
                            style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])
                        )
                )
            }
            .buttonStyle(.plain)

            Text("也可以从「文件」App 或其他应用通过分享菜单把 IPA 投递进来。")
                .font(Typo.micro)
                .fontWeight(.regular)
                .foregroundColor(.secondary)
                .padding(.horizontal, Metric.Space.xs)
        }
    }

    private func selectedFile(_ url: URL) -> some View {
        HStack(spacing: Metric.Space.m) {
            IconBadge(symbol: "doc.zipper", tint: Brand.accent, size: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(url.deletingPathExtension().lastPathComponent)
                    .font(Typo.cardTitle)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(fileSubtitle(url))
                    .font(Typo.caption)
                    .foregroundColor(.secondary)
            }

            Spacer(minLength: Metric.Space.s)

            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Brand.accent)
        }
    }

    private var emptyFileSlot: some View {
        VStack(spacing: Metric.Space.s) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 26, weight: .light))
                .foregroundColor(Brand.accent)
            Text("选择 IPA 文件")
                .font(Typo.cardTitle)
                .foregroundColor(Brand.accent)
            Text("点击从「文件」App 中选取")
                .font(Typo.micro)
                .fontWeight(.regular)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Metric.Space.m)
    }

    /// 沙盒外的 URL 读元数据可能被拒，失败就只显示后缀，别把整行搞崩。
    private func fileSubtitle(_ url: URL) -> String {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.int64Value else {
            return url.pathExtension.uppercased()
        }
        return "\(url.pathExtension.uppercased()) · \(formattedBytes(size))"
    }

    // MARK: - 证书

    private var certificateSection: some View {
        VStack(alignment: .leading, spacing: Metric.Space.s) {
            SectionHeader(title: "签名证书",
                          trailing: model.certificates.isEmpty
                              ? nil : "\(model.certificates.count) 张")

            if model.certificates.isEmpty {
                Card {
                    HStack(spacing: Metric.Space.m) {
                        IconBadge(symbol: "key.slash", tint: Brand.warning, size: 40)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("证书库是空的")
                                .font(Typo.body)
                                .foregroundColor(.primary)
                            Text("需要 p12 证书和配套的 mobileprovision 描述文件。")
                                .font(Typo.caption)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            } else {
                ForEach(model.certificates) { certificate in
                    Button {
                        withAnimation(.easeOut(duration: 0.15)) {
                            selectedCertificate = certificate
                        }
                    } label: {
                        CertificateOptionRow(
                            certificate: certificate,
                            isSelected: selectedCertificate?.id == certificate.id
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 可选改写

    private var advancedSection: some View {
        VStack(alignment: .leading, spacing: Metric.Space.s) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showingAdvanced.toggle()
                }
            } label: {
                HStack(spacing: Metric.Space.s) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(Brand.accent)
                    Text("可选改写")
                        .font(Typo.cardTitle)
                        .foregroundColor(.primary)
                    Spacer()
                    Text(showingAdvanced ? "收起" : "展开")
                        .font(Typo.micro)
                        .fontWeight(.regular)
                        .foregroundColor(.secondary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.secondary)
                        .rotationEffect(.degrees(showingAdvanced ? 180 : 0))
                }
                .padding(Metric.Space.l)
                .background(Brand.surface)
                .clipShape(RoundedRectangle(cornerRadius: Metric.Radius.card,
                                            style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: Metric.Radius.card, style: .continuous)
                        .strokeBorder(Brand.hairline, lineWidth: 0.5)
                )
            }
            .buttonStyle(.plain)

            if showingAdvanced {
                Card {
                    VStack(alignment: .leading, spacing: Metric.Space.l) {
                        field(
                            title: "Bundle ID",
                            placeholder: "留空则保持原值",
                            text: $bundleID,
                            note: "必须落在描述文件的 App ID 覆盖范围内，否则签出来的包装不上。"
                        )

                        Divider().background(Brand.hairline)

                        field(
                            title: "显示名称",
                            placeholder: "留空则保持原值",
                            text: $displayName,
                            note: nil
                        )
                    }
                }
            }
        }
    }

    private func field(title: String,
                       placeholder: String,
                       text: Binding<String>,
                       note: String?) -> some View {
        VStack(alignment: .leading, spacing: Metric.Space.s) {
            Text(title)
                .font(Typo.micro)
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            TextField(placeholder, text: text)
                // 用 disableAutocorrection 而不是 autocorrectionDisabled()：
                // 后者是 iOS 16 才有的 API，而本项目 deployment target 是 15.0。
                .disableAutocorrection(true)
                .textInputAutocapitalization(.never)
                .font(Typo.identifier(14))
                .padding(Metric.Space.m)
                .background(Brand.sunken)
                .clipShape(RoundedRectangle(cornerRadius: Metric.Radius.small,
                                            style: .continuous))

            if let note {
                Text(note)
                    .font(Typo.micro)
                    .fontWeight(.regular)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 校验提示

    @ViewBuilder
    private var blockingNotice: some View {
        if let certificate = selectedCertificate, !certificate.isUsable {
            NoticeBar(level: .warning, text: warning(for: certificate))
        }
    }

    // MARK: - 底部操作条

    private var actionBar: some View {
        VStack(spacing: Metric.Space.s) {
            Button {
                start()
            } label: {
                HStack(spacing: Metric.Space.s) {
                    if isSigning {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .tint(.white)
                    } else {
                        Image(systemName: "signature")
                    }
                    Text(isSigning ? "签名中…" : "开始签名")
                }
            }
            .buttonStyle(PrimaryActionStyle())
            .disabled(!canSign || isSigning)

            if !canSign && !isSigning {
                Text(readinessHint)
                    .font(Typo.micro)
                    .fontWeight(.regular)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, Metric.pageMargin)
        .padding(.top, Metric.Space.m)
        .padding(.bottom, Metric.Space.s)
        .background(.bar)
    }

    private var readinessHint: String {
        if selectedIPA == nil { return "先选一个 IPA" }
        if selectedCertificate == nil { return "再选一张证书" }
        return "所选证书当前不可用"
    }

    // MARK: - 逻辑

    private func prepareSelection() {
        if selectedCertificate == nil {
            selectedCertificate = model.preferredCertificateID
                .flatMap { id in model.certificates.first(where: { $0.id == id }) }
                ?? model.usableCertificates.first
                ?? model.certificates.first
        }
        // 从分享菜单投递进来的 IPA
        if selectedIPA == nil, let pending = model.pendingIPA {
            selectedIPA = pending
            model.pendingIPA = nil
        }
    }

    private var canSign: Bool {
        guard selectedIPA != nil, let certificate = selectedCertificate else { return false }
        // 必须真的可用才算数：只有 p12 没有描述文件、或者两者 Team 对不上，
        // 签出来的包一律装不上 —— 与其让 zsign 跑到一半再报个含糊的错，
        // 不如在按钮这里就拦住。
        return certificate.isUsable
    }

    private func warning(for cert: SigningCertificate) -> String {
        if cert.isExpired {
            return "这张证书已过期，签出来的包无法启动。请换一张，或在开发者后台重新签发。"
        }
        if cert.provisionRelativePath == nil {
            return "缺少配套描述文件，签出来的包无法安装。请删除后重新导入（p12 与描述文件要一起选）。"
        }
        if !cert.isPaired {
            return "证书与描述文件的 Team ID 不一致，签名会被拒绝。"
        }
        return ""
    }

    private func start() {
        guard let ipa = selectedIPA, let cert = selectedCertificate else { return }
        isSigning = true

        Task {
            await model.startSigning(
                input: ipa,
                certificate: cert,
                password: nil,
                bundleID: bundleID.trimmingCharacters(in: .whitespaces),
                displayName: displayName.trimmingCharacters(in: .whitespaces)
            )
            isSigning = false
            dismiss()
        }
    }
}
