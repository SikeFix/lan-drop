import AppKit
import LanDropCore
import SwiftUI

private enum Palette {
    static let canvas = Color(red: 0.973, green: 0.973, blue: 0.961)
    static let sidebar = Color(red: 0.945, green: 0.953, blue: 0.937)
    static let ink = Color(red: 0.12, green: 0.19, blue: 0.18)
    static let muted = Color(red: 0.43, green: 0.49, blue: 0.47)
    static let teal = Color(red: 0.05, green: 0.47, blue: 0.40)
    static let blue = Color(red: 0.22, green: 0.43, blue: 0.82)
    static let line = Color(red: 0.87, green: 0.90, blue: 0.86)
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.isConfigured {
                TransferDashboard(model: model)
            } else {
                PairingView(model: model)
            }
        }
        .foregroundStyle(Palette.ink)
        .background(Palette.canvas)
        .preferredColorScheme(.light)
    }
}

private struct BrandMark: View {
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: "arrow.up.arrow.down")
            .font(.system(size: size * 0.44, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(Palette.teal, in: RoundedRectangle(cornerRadius: size * 0.29))
    }
}

private struct PairingView: View {
    @ObservedObject var model: AppModel
    @State private var name = ""
    @State private var password = ""
    @State private var autoLaunch = true
    @State private var isSubmitting = false
    @FocusState private var focusedField: Field?

    private enum Field { case name, password }
    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && password.count >= 6 && !isSubmitting
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 11) {
                    BrandMark()
                    Text("局域快传").font(.system(size: 21, weight: .semibold))
                }
                Spacer(minLength: 24)
                Text("文件，\n一拖即达。")
                    .font(.system(size: 44, weight: .semibold, design: .rounded))
                    .lineSpacing(9)
                Text("你的两台 Mac，\n从此像在同一张桌面上。")
                    .font(.system(size: 16))
                    .foregroundStyle(Palette.muted)
                    .lineSpacing(6)
                    .padding(.top, 19)
                HStack(spacing: 15) {
                    MacIllustration(caption: "这台 Mac", accent: Palette.teal)
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Palette.teal.opacity(0.6))
                    MacIllustration(caption: "另一台 Mac", accent: Palette.blue)
                }
                .padding(.top, 35)
                Spacer(minLength: 24)
                Label("局域网直传 · 文件留在你的设备上", systemImage: "lock.shield")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 34)
            .padding(.top, 45)
            .padding(.bottom, 30)
            .frame(width: 370)
            .frame(maxHeight: .infinity)
            .background(Palette.sidebar)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 7) {
                    Circle().fill(Palette.teal).frame(width: 6, height: 6)
                    Text("只设置一次").font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Palette.teal)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Palette.teal.opacity(0.07), in: Capsule())
                Text("连接你的另一台 Mac")
                    .font(.system(size: 27, weight: .semibold))
                    .padding(.top, 21)
                Text("两台电脑连上同一网络，输入相同的配对密码。\n以后打开电脑，就能拖入文件自动发送。")
                    .font(.system(size: 13))
                    .foregroundStyle(Palette.muted)
                    .lineSpacing(5)
                    .padding(.top, 11)

                VStack(alignment: .leading, spacing: 20) {
                    fieldLabel("这台 Mac 的名称", detail: "让另一台电脑认出你") {
                        TextField("例如：书房 Mac", text: $name)
                            .focused($focusedField, equals: .name)
                            .onSubmit { focusedField = .password }
                    }
                    fieldLabel("公共配对密码", detail: "两台 Mac 填写相同密码，至少 6 个字符") {
                        SecureField("输入配对密码", text: $password)
                            .focused($focusedField, equals: .password)
                            .onSubmit { submit() }
                    }
                }
                .padding(.top, 29)

                Toggle(isOn: $autoLaunch) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("登录时自动启动").font(.system(size: 13, weight: .medium))
                        Text("关闭窗口后仍可接收，菜单栏随时拖入发送")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                    }
                }
                .toggleStyle(.switch)
                .tint(Palette.teal)
                .padding(.top, 25)

                if let message = model.errorMessage {
                    ErrorBanner(message: message) { model.errorMessage = nil }
                        .padding(.top, 16)
                }

                Button(action: submit) {
                    HStack(spacing: 10) {
                        if isSubmitting { ProgressView().controlSize(.small).tint(.white) }
                        Text(isSubmitting ? "正在保存配对…" : "保存并开始连接")
                        if !isSubmitting { Image(systemName: "arrow.right") }
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 45)
                    .background(canSubmit || isSubmitting ? Palette.teal : Palette.teal.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
                .disabled(!canSubmit)
                .padding(.top, 26)
                Text("密码会安全保存在这台 Mac 上，无需重复输入。")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.muted)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 12)
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 50)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
        .onAppear {
            name = model.deviceName.isEmpty ? Host.current().localizedName ?? "我的 Mac" : model.deviceName
            autoLaunch = model.launchAtLogin
            focusedField = .password
        }
    }

    private func fieldLabel<Content: View>(_ title: String, detail: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .medium))
            content()
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .padding(.horizontal, 13)
                .frame(height: 43)
                .background(.white, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line, lineWidth: 1))
            Text(detail).font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }

    private func submit() {
        guard canSubmit else { return }
        isSubmitting = true
        Task {
            await model.setup(name: name.trimmingCharacters(in: .whitespacesAndNewlines), password: password)
            if model.isConfigured {
                model.updateLaunchAtLogin(autoLaunch)
                password = ""
            }
            isSubmitting = false
        }
    }
}

private struct MacIllustration: View {
    let caption: String
    let accent: Color

    var body: some View {
        VStack(spacing: 9) {
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.78))
                Image(systemName: "laptopcomputer")
                    .font(.system(size: 39, weight: .ultraLight))
                    .foregroundStyle(accent)
            }
            .frame(width: 104, height: 77)
            Text(caption).font(.system(size: 11)).foregroundStyle(Palette.muted)
        }
    }
}

private struct TransferDashboard: View {
    @ObservedObject var model: AppModel
    @State private var isDragging = false
    @State private var showingResetConfirmation = false

    private var selectedPeer: Peer? {
        model.peers.first(where: { $0.id == model.selectedPeerID }) ?? model.peers.first
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            VStack(alignment: .leading, spacing: 21) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("快速发送").font(.system(size: 28, weight: .semibold))
                        Text("拖入即发送，对方自动接收。")
                            .font(.system(size: 13))
                            .foregroundStyle(Palette.muted)
                    }
                    Spacer()
                    Button(action: model.chooseFiles) {
                        Label("选择文件", systemImage: "plus")
                            .font(.system(size: 13, weight: .medium))
                            .padding(.horizontal, 15)
                            .padding(.vertical, 10)
                            .background(.white, in: RoundedRectangle(cornerRadius: 9))
                            .overlay(RoundedRectangle(cornerRadius: 9).stroke(Palette.line, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 5)
                }

                if let message = model.errorMessage {
                    ErrorBanner(message: message) { model.errorMessage = nil }
                }

                dropZone

                HStack {
                    Text("最近传输").font(.system(size: 16, weight: .semibold))
                    if !model.transfers.isEmpty {
                        Text("\(model.transfers.count)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Palette.muted)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Palette.line.opacity(0.55), in: Capsule())
                    }
                    Spacer()
                    Button("清空已结束记录", action: model.clearFinishedTransferRecords)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(model.hasFinishedTransferRecords ? Palette.muted : Palette.muted.opacity(0.45))
                        .buttonStyle(.plain)
                        .disabled(!model.hasFinishedTransferRecords)
                        .help("仅清空已完成或失败的记录，接收的文件会保留。")
                        .padding(.trailing, 10)
                    Button(action: model.revealDownloads) {
                        Label("接收文件夹", systemImage: "folder")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Palette.muted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)

                if model.transfers.isEmpty {
                    VStack(spacing: 9) {
                        Image(systemName: "tray")
                            .font(.system(size: 25, weight: .light))
                            .foregroundStyle(Palette.muted.opacity(0.6))
                        Text("还没有传输记录")
                            .font(.system(size: 12, weight: .medium))
                        Text("发出第一份文件，它会出现在这里。")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.muted)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 10) {
                            ForEach(model.transfers) { transfer in
                                TransferRow(transfer: transfer) {
                                    model.removeTransferRecord(id: transfer.id)
                                }
                            }
                        }
                        .padding(.bottom, 2)
                    }
                    .frame(maxHeight: .infinity)
                }
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down.circle")
                    Text("也可以直接把文件拖到屏幕顶部的菜单栏图标。")
                }
                .font(.system(size: 11))
                .foregroundStyle(Palette.muted)
            }
            .padding(.horizontal, 31)
            .padding(.top, 44)
            .padding(.bottom, 23)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .confirmationDialog("重新设置配对？", isPresented: $showingResetConfirmation) {
            Button("重新设置配对", role: .destructive) { model.resetPairing() }
            Button("取消", role: .cancel) { }
        } message: {
            Text("将移除这台 Mac 保存的配对密码。接收的文件会保留。")
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandMark(size: 34)
                VStack(alignment: .leading, spacing: 3) {
                    Text("局域快传").font(.system(size: 18, weight: .semibold))
                    Text("两台 Mac，一拖即达").font(.system(size: 10)).foregroundStyle(Palette.muted)
                }
            }
            .padding(.bottom, 29)

            HStack(spacing: 7) {
                Circle().fill(model.networkReady ? Palette.teal : Palette.muted).frame(width: 6, height: 6)
                Text(model.statusText).font(.system(size: 11, weight: .medium)).lineLimit(2)
            }
            .foregroundStyle(model.networkReady ? Palette.teal : Palette.muted)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 9))

            Text("这台电脑").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
                .padding(.top, 25).padding(.bottom, 10)
            HStack(spacing: 9) {
                Image(systemName: "laptopcomputer").font(.system(size: 19, weight: .regular))
                Text(model.deviceName).font(.system(size: 12, weight: .medium)).lineLimit(2)
            }

            HStack {
                Text("发送至").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.muted)
                Spacer()
                if !model.peers.isEmpty {
                    Text("\(model.peers.count) 台在线").font(.system(size: 10)).foregroundStyle(Palette.teal)
                }
            }
            .padding(.top, 30).padding(.bottom, 10)

            if model.peers.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) {
                        Image(systemName: "antenna.radiowaves.left.and.right").foregroundStyle(Palette.muted)
                        Text("寻找另一台 Mac…").font(.system(size: 12, weight: .medium))
                    }
                    Text("确认另一台 Mac 已打开局域快传，使用相同密码并连接同一网络。")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.muted)
                        .lineSpacing(4)
                }
                .padding(13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.white.opacity(0.5), in: RoundedRectangle(cornerRadius: 11))
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(model.peers, id: \.id) { peer in
                            Button {
                                model.selectedPeerID = peer.id
                            } label: {
                                HStack(spacing: 9) {
                                    Image(systemName: "laptopcomputer")
                                        .font(.system(size: 19))
                                        .foregroundStyle(Palette.teal)
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(peer.name).font(.system(size: 12, weight: .medium)).lineLimit(2)
                                        Text("已连接 · 自动接收").font(.system(size: 10)).foregroundStyle(Palette.teal)
                                    }
                                    Spacer(minLength: 0)
                                    if selectedPeer?.id == peer.id {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.teal)
                                    }
                                }
                                .padding(12)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.white.opacity(selectedPeer?.id == peer.id ? 1 : 0.55), in: RoundedRectangle(cornerRadius: 11))
                                .overlay(RoundedRectangle(cornerRadius: 11).stroke(selectedPeer?.id == peer.id ? Palette.teal.opacity(0.25) : .clear, lineWidth: 1))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 210)
            }

            Spacer(minLength: 25)

            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 7) {
                    Image(systemName: "lock.fill").font(.system(size: 10))
                    Text("已保存配对密码").font(.system(size: 11))
                    Spacer()
                    Menu {
                        Button("重新设置配对…") { showingResetConfirmation = true }
                    } label: {
                        Image(systemName: "ellipsis").frame(width: 20, height: 18)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("配对设置")
                }
                .foregroundStyle(Palette.muted)
                Rectangle().fill(Palette.line).frame(height: 1)
                Toggle("登录时自动启动", isOn: Binding(get: { model.launchAtLogin }, set: { model.updateLaunchAtLogin($0) }))
                    .font(.system(size: 11))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .tint(Palette.teal)
                Text("关闭窗口后仍在菜单栏运行。")
                    .font(.system(size: 10))
                    .foregroundStyle(Palette.muted)
                Rectangle().fill(Palette.line).frame(height: 1)
                UpdateSettingsView(updater: model.updater)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 42)
        .padding(.bottom, 26)
        .frame(width: 238)
        .frame(maxHeight: .infinity)
        .background(Palette.sidebar)
    }

    private var dropZone: some View {
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 18)
                    .fill(isDragging ? Palette.teal.opacity(0.13) : Palette.teal.opacity(0.07))
                    .frame(width: 67, height: 67)
                Image(systemName: isDragging ? "arrow.down.doc.fill" : "arrow.up.doc")
                    .font(.system(size: 28, weight: .regular))
                    .foregroundStyle(Palette.teal)
                    .offset(y: isDragging ? 3 : 0)
            }
            Text(isDragging ? "松开鼠标，即刻发送" : "把文件拖到这里")
                .font(.system(size: 23, weight: .semibold))
                .padding(.top, 18)
            Text(destinationText)
                .font(.system(size: 12))
                .foregroundStyle(Palette.muted)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .padding(.top, 9)
            HStack(spacing: 5) {
                Image(systemName: "doc.on.doc")
                Text("文件或文件夹 · 支持多个文件")
            }
            .font(.system(size: 10))
            .foregroundStyle(Palette.muted.opacity(0.85))
            .padding(.top, 19)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
        .background(isDragging ? Color.white : Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .stroke(isDragging ? Palette.teal : Palette.line, style: StrokeStyle(lineWidth: isDragging ? 2 : 1.5, dash: isDragging ? [] : [7, 6]))
        }
        .overlay {
            FileDropSurface(isDragging: $isDragging, onDrop: model.receiveURLs, onClick: model.chooseFiles)
        }
        .animation(.easeInOut(duration: 0.18), value: isDragging)
    }

    private var destinationText: String {
        if let peer = selectedPeer { return "自动发送至 \(peer.name)" }
        return "设备连接后，文件会自动发送"
    }
}

private struct UpdateSettingsView: View {
    @ObservedObject var updater: UpdateController

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("版本 \(version)").font(.system(size: 10))
                Spacer()
                Button("检查更新…", action: updater.checkForUpdates)
                    .font(.system(size: 10, weight: .medium))
                    .buttonStyle(.plain)
                    .foregroundStyle(updater.canCheckForUpdates ? Palette.teal : Palette.muted)
                    .disabled(!updater.canCheckForUpdates)
            }
            Toggle("自动更新", isOn: Binding(get: { updater.automaticUpdatesEnabled }, set: updater.setAutomaticUpdatesEnabled))
                .font(.system(size: 11))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Palette.teal)
                .help("自动获取新版本，传输期间会等待。")
            if !updater.statusText.isEmpty {
                Text(updater.statusText)
                    .font(.system(size: 10))
                    .lineSpacing(3)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(Palette.muted)
    }
}

private struct TransferRow: View {
    let transfer: TransferItem
    let onDelete: () -> Void

    private var isSending: Bool { transfer.direction == .sending }
    private var canDelete: Bool { transfer.state == .completed || transfer.state == .failed }
    private var fraction: Double { transfer.fraction.isFinite ? min(max(transfer.fraction, 0), 1) : 0 }
    private var stateColor: Color {
        switch transfer.state {
        case .completed: return Palette.teal
        case .failed: return Color(red: 0.76, green: 0.27, blue: 0.21)
        case .waiting: return Palette.muted
        case .transferring: return Palette.blue
        }
    }
    private var status: String {
        switch transfer.state {
        case .completed: return isSending ? "已发送" : "已接收"
        case .failed: return "传输失败"
        case .waiting: return "等待连接"
        case .transferring: return "\(Int(fraction * 100))%"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: fileIcon)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(isSending ? Palette.blue : Palette.teal)
                .frame(width: 42, height: 45)
                .background((isSending ? Palette.blue : Palette.teal).opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(transfer.filename)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(transfer.filename)
                    Spacer(minLength: 0)
                    HStack(spacing: 4) {
                        if transfer.state == .completed {
                            Image(systemName: "checkmark.circle.fill")
                        } else if transfer.state == .failed {
                            Image(systemName: "exclamationmark.circle.fill")
                        }
                        Text(status)
                        if transfer.state == .transferring, let speed = speedText {
                            Text("· \(speed)")
                        }
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(stateColor)
                }
                HStack(spacing: 6) {
                    Image(systemName: isSending ? "arrow.up.right" : "arrow.down.left")
                    Text("\(isSending ? "发往" : "来自") \(transfer.peerName)")
                        .lineLimit(1)
                    if transfer.totalBytes > 0 {
                        Text("· \(ByteCountFormatter.string(fromByteCount: transfer.totalBytes, countStyle: .file))")
                    }
                    Spacer(minLength: 0)
                    if transfer.state == .completed, let url = transfer.fileURL {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        } label: {
                            Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                        }
                        .buttonStyle(.plain)
                        .help("在 Finder 中显示")
                    }
                    if canDelete {
                        Button(action: onDelete) {
                            Image(systemName: "trash")
                                .foregroundStyle(Palette.muted)
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("删除传输记录")
                        .help("删除这条记录，接收的文件会保留。")
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(Palette.muted)

                if transfer.state == .transferring {
                    ProgressView(value: fraction).tint(Palette.blue).controlSize(.small)
                }
                if !transfer.detail.isEmpty && transfer.state != .completed {
                    Text(transfer.detail)
                        .font(.system(size: 10))
                        .foregroundStyle(transfer.state == .failed ? stateColor : Palette.muted)
                        .lineLimit(3)
                }
            }
            .padding(.top, 4)
        }
        .padding(13)
        .background(.white, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.line.opacity(0.6), lineWidth: 1))
        .contextMenu {
            if canDelete {
                Button("删除记录（保留文件）", action: onDelete)
            }
        }
    }

    private var speedText: String? {
        guard transfer.bytesPerSecond.isFinite, transfer.bytesPerSecond > 0 else { return nil }
        if transfer.bytesPerSecond >= 1_000_000 {
            return String(format: "%.1f MB/s", transfer.bytesPerSecond / 1_000_000)
        }
        return String(format: "%.0f KB/s", transfer.bytesPerSecond / 1_000)
    }

    private var fileIcon: String {
        switch (transfer.filename as NSString).pathExtension.lowercased() {
        case "png", "jpg", "jpeg", "gif", "heic", "webp": return "photo"
        case "zip", "gz", "tar", "7z", "rar": return "doc.zipper"
        case "mp4", "mov", "m4v", "avi": return "film"
        case "mp3", "wav", "m4a", "flac": return "music.note"
        case "pdf": return "doc.richtext"
        default: return "doc"
        }
    }
}

private struct ErrorBanner: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "exclamationmark.circle.fill").padding(.top, 1)
            Text(message).font(.system(size: 11)).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)) }
                .buttonStyle(.plain)
                .help("关闭提示")
        }
        .foregroundStyle(Color(red: 0.62, green: 0.28, blue: 0.14))
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(red: 1, green: 0.94, blue: 0.86), in: RoundedRectangle(cornerRadius: 9))
    }
}

private struct FileDropSurface: NSViewRepresentable {
    @Binding var isDragging: Bool
    let onDrop: ([URL]) -> Void
    let onClick: () -> Void

    func makeNSView(context: Context) -> FileDropView {
        let view = FileDropView()
        view.registerForDraggedTypes([.fileURL])
        view.setAccessibilityLabel("拖入文件或文件夹即可发送，点击选择文件")
        view.toolTip = "拖入文件或文件夹即可发送；点击选择文件"
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: FileDropView, context: Context) {
        nsView.onHover = { isDragging = $0 }
        nsView.onDrop = onDrop
        nsView.onClick = onClick
    }

    final class FileDropView: NSView {
        var onHover: ((Bool) -> Void)?
        var onDrop: (([URL]) -> Void)?
        var onClick: (() -> Void)?

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            guard !fileURLs(from: sender.draggingPasteboard).isEmpty else { return [] }
            onHover?(true)
            return .copy
        }

        override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }
        override func draggingExited(_ sender: NSDraggingInfo?) { onHover?(false) }
        override func draggingEnded(_ sender: NSDraggingInfo) { onHover?(false) }

        override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
            !fileURLs(from: sender.draggingPasteboard).isEmpty
        }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let urls = fileURLs(from: sender.draggingPasteboard)
            onHover?(false)
            guard !urls.isEmpty else { return false }
            onDrop?(urls)
            return true
        }

        override func mouseDown(with event: NSEvent) { onClick?() }
    }
}

func fileURLs(from pasteboard: NSPasteboard) -> [URL] {
    let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []
    return objects.compactMap { ($0 as? NSURL).map { $0 as URL } }.filter(\.isFileURL)
}
