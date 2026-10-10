import LCSignCore
import SwiftUI
import UniformTypeIdentifiers

// MARK: - 单行展示

struct CertificateRow: View {

    let certificate: SigningCertificate
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 12) {

            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.accentColor)
                .opacity(isSelected ? 1 : 0)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(certificate.displayName)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(.primary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Text(certificate.teamID.isEmpty ? "未知 Team" : certificate.teamID)
                    if let provision = certificate.provision {
                        Text("·")
                        Text(provision.applicationIdentifier)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption)
                .foregroundColor(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(certificate.expiryDescription)
                    .font(.caption2)
                    .foregroundColor(tint)

                if certificate.provisionRelativePath == nil {
                    Text("缺描述文件")
                        .font(.caption2)
                        .foregroundColor(.orange)
                } else if !certificate.isPaired {
                    Text("Team 不匹配")
                        .font(.caption2)
                        .foregroundColor(.red)
                }
            }
        }
        .contentShape(Rectangle())
    }

    private var tint: Color {
        switch certificate.expiryLevel {
        case .healthy:  return .secondary
        case .warning:  return .orange
        case .critical: return .red
        case .expired:  return .red
        }
    }
}

// MARK: - 证书列表

struct CertificateListView: View {

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @State private var showingImporter = false

    var body: some View {
        NavigationView {
            List {
                if model.certificates.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("还没有导入证书")
                                .font(.headline)
                            Text("需要同时准备 p12 证书和配套的 mobileprovision 描述文件。"
                               + "只有 p12 是签不出可安装的包的。")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                        .padding(.vertical, 6)
                    }
                } else {
                    Section {
                        ForEach(model.certificates) { cert in
                            CertificateRow(certificate: cert)
                        }
                        .onDelete { indexSet in
                            let targets = indexSet.map { model.certificates[$0] }
                            Task {
                                for cert in targets {
                                    await model.remove(cert)
                                }
                            }
                        }
                    } header: {
                        Text("已导入")
                    } footer: {
                        Text("左滑可删除。证书密码保存在系统钥匙串，不会随证书文件一起删除。")
                    }
                }
            }
            .listStyle(.insetGrouped)
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
        }
        .navigationViewStyle(.stack)
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
    @State private var isImporting = false

    var body: some View {
        NavigationView {
            Form {

                Section {
                    Button {
                        showingP12Picker = true
                    } label: {
                        pickerRow(title: "证书文件 (.p12)",
                                  value: p12URL?.lastPathComponent)
                    }

                    SecureField("p12 导出密码", text: $password)
                        .textContentType(.password)

                } header: {
                    Text("证书")
                } footer: {
                    Text("密码会存进系统钥匙串，不会明文保存在应用目录里。")
                }

                Section {
                    Button {
                        showingProvisionPicker = true
                    } label: {
                        pickerRow(title: "描述文件 (.mobileprovision)",
                                  value: provisionURL?.lastPathComponent)
                    }
                } header: {
                    Text("描述文件")
                } footer: {
                    Text("必须与证书同属一个 Team，否则导入会被拒绝。")
                }

                Section("备注名称") {
                    TextField("留空则使用证书的通用名", text: $displayName)
                }

                Section {
                    Button {
                        Task { await performImport() }
                    } label: {
                        HStack {
                            Spacer()
                            if isImporting {
                                ProgressView().padding(.trailing, 6)
                            }
                            Text(isImporting ? "导入中…" : "导入")
                                .fontWeight(.medium)
                            Spacer()
                        }
                    }
                    .disabled(p12URL == nil || provisionURL == nil || isImporting)
                }
            }
            .navigationTitle("导入证书")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isImporting)
                }
            }
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

    private func pickerRow(title: String, value: String?) -> some View {
        HStack {
            Text(title)
                .foregroundColor(.primary)
            Spacer()
            Text(value ?? "未选择")
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func performImport() async {
        guard let p12 = p12URL, let provision = provisionURL else { return }
        isImporting = true
        await model.importCertificate(
            p12: p12,
            password: password,
            provision: provision
        )
        isImporting = false
        if model.alert == nil { dismiss() }
    }
}
