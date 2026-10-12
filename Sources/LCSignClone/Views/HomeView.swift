import LCSignCore
import SwiftUI
import UIKit

struct HomeView: View {

    @EnvironmentObject private var model: AppModel

    /// 三个弹窗共用一个状态。
    ///
    /// 不要写成三个并列的 `.sheet(isPresented:)` —— SwiftUI 对同一个视图上
    /// 叠加多个 sheet 的处理并不一致，实测只有最后一个能稳定弹出来。
    @State private var activeSheet: ActiveSheet?

    private enum ActiveSheet: String, Identifiable {
        case sign, certificates, diagnostics
        var id: String { rawValue }
    }

    var body: some View {
        navigationContent
            .navigationViewStyle(.stack)
            .task {
                await model.refreshCertificates()
            }
            .sheet(item: $activeSheet) { sheet in
                switch sheet {
                case .sign:         SignSheet()
                case .certificates: CertificateListView()
                case .diagnostics:  DiagnosticsView()
                }
            }
            .alert(
                model.alert?.title ?? "",
                isPresented: isShowingAlert,
                presenting: model.alert
            ) { _ in
                Button("好", role: .cancel) {}
            } message: { payload in
                Text(payload.message)
            }
    }

    /// 拆出来单独算：直接写在 body 里会让类型检查器在
    /// NavigationView + toolbar + sheet + alert 的链式调用上超时。
    private var isShowingAlert: Binding<Bool> {
        Binding(
            get: { model.alert != nil },
            set: { if !$0 { model.alert = nil } }
        )
    }

    private var navigationContent: some View {
        NavigationView {
            Group {
                if model.tasks.isEmpty {
                    emptyState
                } else {
                    taskList
                }
            }
            .navigationTitle("LCSign")
            .toolbar { toolbarContent }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button {
                activeSheet = .certificates
            } label: {
                Label("证书", systemImage: "key.fill")
            }
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                activeSheet = .sign
            } label: {
                Label("签名", systemImage: "plus.circle.fill")
            }
            .disabled(model.certificates.isEmpty)
        }
        ToolbarItem(placement: .navigationBarTrailing) {
            Button {
                activeSheet = .diagnostics
            } label: {
                Label("诊断", systemImage: "stethoscope")
            }
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "signature")
                .font(.system(size: 52, weight: .light))
                .foregroundColor(.secondary)

            Text("还没有签名任务")
                .font(.headline)

            Text(model.certificates.isEmpty
                 ? "先在左上角导入证书（p12 + 描述文件），然后点右上角选择 IPA。"
                 : "点右上角选择要重签名的 IPA 文件。")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            if model.certificates.isEmpty {
                Button {
                    activeSheet = .certificates
                } label: {
                    Label("导入证书", systemImage: "key.fill")
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)

                Button {
                    activeSheet = .diagnostics
                } label: {
                    Label("先跑一次引擎自检", systemImage: "stethoscope")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 任务列表

    private var taskList: some View {
        List {
            Section {
                ForEach(model.tasks) { task in
                    TaskRow(task: task)
                }
            } header: {
                Text("任务")
            } footer: {
                Text("签名产物保存在「文件」App → 我的 iPhone → LCSign → Signed 目录下。")
            }
        }
        .listStyle(.insetGrouped)
    }
}

// MARK: - 单条任务

struct TaskRow: View {

    let task: SigningTask

    @State private var showingShare = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            HStack(spacing: 10) {
                statusIcon
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.name)
                        .font(.system(size: 15, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(task.stage)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }

            if task.isRunning {
                ProgressView(value: task.fraction)
                    .progressViewStyle(.linear)
            }

            if case .failed(let message) = task.status {
                Text(message)
                    .font(.caption)
                    .foregroundColor(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let output = task.outputURL, task.status == .success {
                Button {
                    showingShare = true
                } label: {
                    Label("导出 IPA", systemImage: "square.and.arrow.up")
                        .font(.caption)
                }
                .sheet(isPresented: $showingShare) {
                    ActivityView(items: [output])
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch task.status {
        case .running:
            ProgressView()
                .frame(width: 22, height: 22)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.system(size: 22))
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.orange)
                .font(.system(size: 22))
        }
    }
}

// MARK: - 分享面板

/// 用 UIActivityViewController 而不是 ShareLink —— 后者需要 iOS 16，
/// 而本项目的 deployment target 是 15.0。
struct ActivityView: UIViewControllerRepresentable {

    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController,
                                context: Context) {}
}
