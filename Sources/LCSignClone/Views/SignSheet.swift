import SwiftUI
import UniformTypeIdentifiers

struct SignSheet: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var selectedIPA: URL?
    @State private var selectedCertificate: SigningCertificate?
    @State private var bundleID = ""
    @State private var displayName = ""

    @State private var showingIPAPicker = false
    @State private var isSigning = false

    var body: some View {
        NavigationView {
            Form {

                // ---- IPA ----
                Section {
                    Button {
                        showingIPAPicker = true
                    } label: {
                        HStack {
                            Label("选择 IPA", systemImage: "doc.zipper")
                            Spacer()
                            if let selectedIPA {
                                Text(selectedIPA.deletingPathExtension().lastPathComponent)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                    }
                } header: {
                    Text("待签名的应用")
                } footer: {
                    Text("也可以直接从「文件」App 或其他应用通过分享菜单投递 IPA 进来。")
                }

                // ---- 证书 ----
                Section("签名证书") {
                    if model.certificates.isEmpty {
                        Text("证书库是空的，请先导入 p12 与描述文件。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    } else {
                        ForEach(model.certificates) { cert in
                            Button {
                                selectedCertificate = cert
                            } label: {
                                CertificateRow(
                                    certificate: cert,
                                    isSelected: selectedCertificate?.id == cert.id
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // ---- 可选改写 ----
                Section {
                    TextField("留空则保持原值", text: $bundleID)
                        // 用 disableAutocorrection 而不是 autocorrectionDisabled()：
                        // 后者是 iOS 16 才有的 API，而本项目 deployment target 是 15.0。
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                } header: {
                    Text("Bundle ID")
                } footer: {
                    Text("必须落在描述文件的 App ID 覆盖范围内，否则签出来的包装不上。")
                }

                Section("显示名称") {
                    TextField("留空则保持原值", text: $displayName)
                }

                // ---- 执行 ----
                Section {
                    Button {
                        start()
                    } label: {
                        HStack {
                            Spacer()
                            if isSigning {
                                ProgressView()
                                    .padding(.trailing, 6)
                            }
                            Text(isSigning ? "签名中…" : "开始签名")
                                .fontWeight(.medium)
                            Spacer()
                        }
                    }
                    .disabled(!canSign || isSigning)
                } footer: {
                    if let cert = selectedCertificate, !cert.isUsable {
                        Text(warning(for: cert))
                            .foregroundColor(.orange)
                    }
                }
            }
            .navigationTitle("重签名")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSigning)
                }
            }
            .fileImporter(
                isPresented: $showingIPAPicker,
                allowedContentTypes: [.ipaArchive],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    selectedIPA = url
                }
            }
            .onAppear {
                if selectedCertificate == nil {
                    selectedCertificate = model.certificates.first(where: \.isUsable)
                        ?? model.certificates.first
                }
                // 从分享菜单投递进来的 IPA
                if selectedIPA == nil, let pending = model.pendingIPA {
                    selectedIPA = pending
                    model.pendingIPA = nil
                }
            }
        }
        .navigationViewStyle(.stack)
    }

    // MARK: - 逻辑

    private var canSign: Bool {
        selectedIPA != nil && selectedCertificate != nil
    }

    private func warning(for cert: SigningCertificate) -> String {
        if cert.isExpired {
            return "这张证书已过期，签出来的包无法启动。"
        }
        if cert.provisionRelativePath == nil {
            return "缺少配套描述文件，签出来的包无法安装。请删除后重新导入。"
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
