import LCSignCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 可选择行（签名页用）

/// 签名页里的证书选项。左侧圆点表示选中态，
/// 右侧用胶囊把「不可用」的原因直接写出来 —— 不写的话用户只会看到按钮点不动。
struct CertificateOptionRow: View {

    let certificate: SigningCertificate
    let isSelected: Bool

    var body: some View {
        Card(padding: Metric.Space.m) {
            HStack(spacing: Metric.Space.m) {
                selectionIndicator

                VStack(alignment: .leading, spacing: 3) {
                    Text(certificate.displayName)
                        .font(Typo.cardTitle)
                        .foregroundColor(.primary)
                        .lineLimit(1)

                    HStack(spacing: 5) {
                        Text(certificate.teamID.isEmpty ? "未知 Team" : certificate.teamID)
                            .font(Typo.identifier(11))
                        if let provision = certificate.provision {
                            Text("·")
                            Text(provision.applicationIdentifier)
                                .font(Typo.identifier(11))
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .foregroundColor(.secondary)
                }

                Spacer(minLength: Metric.Space.s)

                VStack(alignment: .trailing, spacing: Metric.Space.xs) {
                    StatusPill(text: certificate.expiryDescription,
                               tint: Brand.tint(for: certificate.expiryLevel))
                    if let problem = problemLabel {
                        StatusPill(text: problem, tint: Brand.danger)
                    }
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Metric.Radius.card, style: .continuous)
                .strokeBorder(isSelected ? Brand.accent : Color.clear, lineWidth: 1.6)
        )
    }

    private var selectionIndicator: some View {
        ZStack {
            Circle()
                .strokeBorder(isSelected ? Brand.accent : Brand.hairline,
                              lineWidth: isSelected ? 6 : 1.5)
                .frame(width: 22, height: 22)
        }
    }

    private var problemLabel: String? {
        if certificate.isExpired { return "已过期" }
        if certificate.provisionRelativePath == nil { return "缺描述文件" }
        if !certificate.isPaired { return "Team 不匹配" }
        return nil
    }
}

// MARK: - 列表行（证书库用）

struct CertificateListRow: View {

    let certificate: SigningCertificate
    let onDelete: () -> Void

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Metric.Space.m) {
                HStack(alignment: .top, spacing: Metric.Space.m) {
                    IconBadge(symbol: certificate.isUsable ? "checkmark.seal.fill" : "exclamationmark.seal.fill",
                              tint: certificate.isUsable
                                  ? Brand.success
                                  : Brand.tint(for: certificate.expiryLevel),
                              size: 42)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(certificate.displayName)
                            .font(Typo.cardTitle)
                            .foregroundColor(.primary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(certificate.commonName)
                            .font(Typo.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: Metric.Space.s)

                    Menu {
                        Button(role: .destructive, action: onDelete) {
                            Label("删除证书", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.secondary)
                            .frame(width: 32, height: 32)
                            .background(Brand.sunken)
                            .clipShape(Circle())
                    }
                }

                VStack(alignment: .leading, spacing: Metric.Space.s) {
                    infoLine(title: "Team ID",
                             value: certificate.teamID.isEmpty ? "未知" : certificate.teamID)
                    if let provision = certificate.provision {
                        infoLine(title: "App ID", value: provision.applicationIdentifier)
                        infoLine(title: "设备数", value: "\(provision.provisionedDeviceCount) 台")
                    } else {
                        infoLine(title: "描述文件", value: "缺失 —— 签出来的包无法安装")
                    }
                }

                VStack(alignment: .leading, spacing: Metric.Space.xs) {
                    HStack {
                        Text(certificate.expiryDescription)
                            .font(Typo.micro)
                            .fontWeight(.regular)
                            .foregroundColor(Brand.tint(for: certificate.expiryLevel))
                        Spacer()
                        if !certificate.isUsable {
                            Text(problemLabel)
                                .font(Typo.micro)
                                .foregroundColor(Brand.danger)
                        }
                    }
                    Meter(value: validityFraction,
                          tint: Brand.tint(for: certificate.expiryLevel))
                }
            }
        }
    }

    private func infoLine(title: String, value: String) -> some View {
        HStack(alignment: .top, spacing: Metric.Space.s) {
            Text(title)
                .font(Typo.micro)
                .fontWeight(.regular)
                .foregroundColor(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(value)
                .font(Typo.identifier(11))
                .foregroundColor(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var validityFraction: Double {
        guard !certificate.isExpired else { return 0 }
        return min(1, Double(certificate.daysRemaining) / 365)
    }

    private var problemLabel: String {
        if certificate.isExpired { return "已过期" }
        if certificate.provisionRelativePath == nil { return "缺描述文件" }
        if !certificate.isPaired { return "Team 不匹配" }
        return "不可用"
    }
}

// MARK: - 证书库

struct CertificateListView: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var showingImporter = false
    @State private var pendingDeletion: SigningCertificate?

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: Metric.Space.l) {
                    if model.certificates.isEmpty {
                        emptyState
                    } else {
                        summary
                        ForEach(model.certificates) { certificate in
                            CertificateListRow(certificate: certificate) {
                                pendingDeletion = certificate
                            }
                        }
                        note
                    }
                }
                .padding(.horizontal, Metric.pageMargin)
                .padding(.bottom, Metric.Space.xxl)
            }
            .background(Brand.canvas.ignoresSafeArea())
            .navigationTitle("证书库")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showingImporter = true
                    } label: {
                        Label("导入", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingImporter) {
                ImportCertificateSheet()
            }
            .confirmationDialog(
                "删除这张证书？",
                isPresented: isShowingDeletion,
                presenting: pendingDeletion
            ) { certificate in
                Button("删除", role: .destructive) {
                    Task { await model.remove(certificate) }
                }
                Button("取消", role: .cancel) {}
            } message: { certificate in
                Text("「\(certificate.displayName)」的 p12 与描述文件会一并删除。"
                   + "钥匙串里保存的密码也会被清掉，此操作不可撤销。")
            }
        }
        .navigationViewStyle(.stack)
    }

    private var isShowingDeletion: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private var emptyState: some View {
        Card {
            EmptyState(
                symbol: "key.fill",
                title: "还没有导入证书",
                message: "需要同时准备 p12 证书和配套的 mobileprovision 描述文件。"
                       + "只有 p12 是签不出可安装的包的。"
            ) {
                Button {
                    showingImporter = true
                } label: {
                    Label("导入证书", systemImage: "plus")
                }
                .buttonStyle(PrimaryActionStyle(compact: true))
            }
        }
    }

    private var summary: some View {
        Card {
            HStack(spacing: Metric.Space.l) {
                summaryItem(value: "\(model.certificates.count)",
                            title: "已导入",
                            tint: Brand.accent)
                Rectangle().fill(Brand.hairline).frame(width: 1, height: 30)
                summaryItem(value: "\(model.usableCertificates.count)",
                            title: "可用",
                            tint: Brand.success)
                Rectangle().fill(Brand.hairline).frame(width: 1, height: 30)
                summaryItem(value: "\(model.certificates.count - model.usableCertificates.count)",
                            title: "有问题",
                            tint: model.certificates.count == model.usableCertificates.count
                                ? .secondary : Brand.danger)
            }
        }
    }

    private func summaryItem(value: String, title: String, tint: Color) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded))
                .foregroundColor(tint)
                .monospacedDigit()
            Text(title)
                .font(Typo.micro)
                .fontWeight(.regular)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var note: some View {
        Text("点右上角「+」继续导入。删除请点卡片右上角的「⋯」。"
           + "证书密码保存在系统钥匙串，不会随证书文件一起删除。")
            .font(Typo.micro)
            .fontWeight(.regular)
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, Metric.Space.s)
    }
}

// MARK: - 导入证书

struct ImportCertificateSheet: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var p12URL: URL?
    @State private var provisionURL: URL?
    @State private var password = ""
    @State private var displayName = ""

    @State private var showingP12Picker = false
    @State private var showingProvisionPicker = false
    @State private var isPasswordVisible = false
    @State private var isImporting = false

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: Metric.Space.l) {
                    fileSection
                    passwordSection
                    nameSection
                    checklist
                }
                .padding(.horizontal, Metric.pageMargin)
                .padding(.bottom, Metric.Space.xxl)
            }
            .background(Brand.canvas.ignoresSafeArea())
            .navigationTitle("导入证书")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isImporting)
                }
            }
            .safeAreaInset(edge: .bottom) { actionBar }
            .fileImporter(isPresented: $showingP12Picker,
                          allowedContentTypes: [.pkcs12, .data],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { p12URL = url }
            }
            .fileImporter(isPresented: $showingProvisionPicker,
                          allowedContentTypes: [.mobileProvision, .data],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { provisionURL = url }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: 文件

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: Metric.Space.s) {
            SectionHeader(title: "证书文件")

            Button {
                showingP12Picker = true
            } label: {
                pickerCard(
                    symbol: "key.fill",
                    title: "证书 (.p12)",
                    value: p12URL?.lastPathComponent,
                    hint: "从钥匙串导出的 .p12 文件",
                    tint: Brand.accent
                )
            }
            .buttonStyle(.plain)

            Button {
                showingProvisionPicker = true
            } label: {
                pickerCard(
                    symbol: "doc.text.fill",
                    title: "描述文件 (.mobileprovision)",
                    value: provisionURL?.lastPathComponent,
                    hint: "必须与证书同属一个 Team",
                    tint: Brand.accent
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func pickerCard(symbol: String,
                            title: String,
                            value: String?,
                            hint: String,
                            tint: Color) -> some View {
        Card(padding: Metric.Space.m) {
            HStack(spacing: Metric.Space.m) {
                IconBadge(symbol: symbol,
                          tint: value == nil ? .secondary : tint,
                          size: 40)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(Typo.caption)
                        .foregroundColor(.secondary)

                    Text(value ?? "未选择")
                        .font(value == nil ? Typo.caption : Typo.identifier(12))
                        .foregroundColor(value == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: Metric.Space.s)

                Image(systemName: value == nil ? "plus.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundColor(value == nil ? tint : Brand.success)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: Metric.Radius.card, style: .continuous)
                .strokeBorder(value == nil ? Brand.hairline : Brand.success.opacity(0.5),
                              lineWidth: value == nil ? 0.5 : 1.2)
        )
    }

    // MARK: 密码

    private var passwordSection: some View {
        VStack(alignment: .leading, spacing: Metric.Space.s) {
            SectionHeader(title: "p12 导出密码")

            Card {
                VStack(alignment: .leading, spacing: Metric.Space.s) {
                    HStack(spacing: Metric.Space.s) {
                        Group {
                            if isPasswordVisible {
                                TextField("导出时设置的密码", text: $password)
                            } else {
                                SecureField("导出时设置的密码", text: $password)
                            }
                        }
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                        .font(Typo.identifier(14))

                        Button {
                            isPasswordVisible.toggle()
                        } label: {
                            Image(systemName: isPasswordVisible ? "eye.slash.fill" : "eye.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(Metric.Space.m)
                    .background(Brand.sunken)
                    .clipShape(RoundedRectangle(cornerRadius: Metric.Radius.small,
                                                style: .continuous))

                    Text("导入时会用这个密码试开一次 p12，密码不对会当场报错。"
                       + "密码随后存进系统钥匙串，不会明文写进应用目录。")
                        .font(Typo.micro)
                        .fontWeight(.regular)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: Metric.Space.s) {
            SectionHeader(title: "备注名称")

            Card {
                TextField("留空则使用证书的通用名", text: $displayName)
                    .disableAutocorrection(true)
                    .font(Typo.body)
                    .padding(Metric.Space.m)
                    .background(Brand.sunken)
                    .clipShape(RoundedRectangle(cornerRadius: Metric.Radius.small,
                                                style: .continuous))
            }
        }
    }

    // MARK: 就绪检查

    private var checklist: some View {
        VStack(alignment: .leading, spacing: Metric.Space.s) {
            SectionHeader(title: "就绪检查")

            Card {
                VStack(alignment: .leading, spacing: Metric.Space.m) {
                    checkRow("已选择 p12 证书", done: p12URL != nil)
                    checkRow("已填写导出密码", done: !password.isEmpty)
                    checkRow("已选择描述文件", done: provisionURL != nil)
                }
            }
        }
    }

    private func checkRow(_ title: String, done: Bool) -> some View {
        HStack(spacing: Metric.Space.s) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15))
                .foregroundColor(done ? Brand.success : Brand.hairline)
            Text(title)
                .font(Typo.caption)
                .foregroundColor(done ? .primary : .secondary)
            Spacer()
        }
    }

    // MARK: 操作条

    private var actionBar: some View {
        VStack(spacing: Metric.Space.s) {
            Button {
                Task { await performImport() }
            } label: {
                HStack(spacing: Metric.Space.s) {
                    if isImporting {
                        ProgressView().progressViewStyle(.circular).tint(.white)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                    }
                    Text(isImporting ? "导入中…" : "导入")
                }
            }
            .buttonStyle(PrimaryActionStyle())
            .disabled(!canImport || isImporting)

            if !canImport && !isImporting {
                Text("p12、密码、描述文件三者齐全才能导入")
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

    private var canImport: Bool {
        p12URL != nil && provisionURL != nil && !password.isEmpty
    }

    private func performImport() async {
        guard let p12 = p12URL, let provision = provisionURL else { return }
        isImporting = true
        let succeeded = await model.importCertificate(
            p12: p12,
            password: password,
            provision: provision,
            displayName: displayName.trimmingCharacters(in: .whitespaces)
        )
        isImporting = false
        if succeeded { dismiss() }
    }
}
