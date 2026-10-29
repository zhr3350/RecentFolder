import SwiftUI

/// 菜单栏下拉面板：最近目录 / 常用目录 / 权限状态
struct HistoryPanelView: View {

    @ObservedObject var model: HistoryModel
    @ObservedObject var permissions: PermissionCenter
    @AppStorage("savePromptEnabled") private var savePromptEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if model.records.isEmpty {
                emptyState
            } else {
                if !model.pinnedRecords.isEmpty {
                    sectionTitle("常用目录")
                    ForEach(model.pinnedRecords) { record in
                        row(record)
                    }
                    if !model.recentRecords.isEmpty {
                        Divider().padding(.vertical, 4)
                    }
                }
                if !model.recentRecords.isEmpty {
                    sectionTitle("最近目录")
                    ForEach(model.recentRecords) { record in
                        row(record)
                    }
                }
            }

            Divider()
            footer
        }
        .frame(width: 340)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        HStack {
            Text("最近文件夹")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                model.reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("刷新")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("还没有记录")
                .font(.system(size: 12))
            Text("在访达里打开一些文件夹后会自动记录")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 6)
            .padding(.bottom, 2)
    }

    private func row(_ record: FolderRecord) -> some View {
        HStack(spacing: 8) {
            Image(systemName: record.isPinned ? "pin.fill" : "folder")
                .font(.system(size: 11))
                .foregroundStyle(record.isPinned ? Color.accentColor : .secondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 1) {
                Text(record.displayName)
                    .font(.system(size: 12))
                    .lineLimit(1)
                Text(record.path)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 4)

            Button {
                model.togglePin(record)
            } label: {
                Image(systemName: record.isPinned ? "pin.slash" : "pin")
            }
            .buttonStyle(.plain)
            .help(record.isPinned ? "取消常用" : "置顶为常用")

            Button {
                model.reveal(record)
            } label: {
                Image(systemName: "arrow.right.circle")
            }
            .buttonStyle(.plain)
            .help("在访达中显示")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture { model.copyPath(record) }
        .contextMenu {
            Button("复制路径") { model.copyPath(record) }
            Button("在访达中显示") { model.reveal(record) }
            Button(record.isPinned ? "取消常用" : "置顶为常用") { model.togglePin(record) }
            Divider()
            Button("从列表移除") { model.remove(record) }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: $savePromptEnabled) {
                Text("保存时浮出最近文件夹候选")
                    .font(.system(size: 11))
            }
            .toggleStyle(.switch)
            .controlSize(.mini)

            if !permissions.accessibilityGranted {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text("未授权辅助功能，保存对话框自动跳转不可用")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("去授权") { permissions.requestAccessibility() }
                        .font(.system(size: 10))
                        .buttonStyle(.link)
                }
            }

            HStack {
                Text(SharedPaths.sharedDirectory().path)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
                    .font(.system(size: 10))
                    .buttonStyle(.link)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
