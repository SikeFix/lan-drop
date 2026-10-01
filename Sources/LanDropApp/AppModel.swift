import AppKit
import Combine
import Foundation
import LanDropCore
import Security
import ServiceManagement
import UserNotifications

typealias TransferItem = TransferProgress

@MainActor
final class AppModel: ObservableObject {
    let updater = UpdateController()
    @Published var isConfigured = false
    @Published var peers: [Peer] = []
    @Published var transfers: [TransferItem] = []
    @Published var statusText = "输入一次密码，之后直接拖放"
    @Published var errorMessage: String?
    @Published var deviceName: String
    @Published var networkReady = false
    @Published var selectedPeerID: UUID? {
        didSet {
            UserDefaults.standard.set(selectedPeerID?.uuidString, forKey: "selectedPeerID")
            Task { await engine?.selectPeer(selectedPeerID) }
        }
    }
    @Published var launchAtLogin: Bool
    let receiveDirectory: URL
    private let deviceID: UUID
    private var engine: TransferEngine?
    private var eventTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var lifecycle = UUID()
    private var pendingSubmissions = 0

    var hasPendingTransfers: Bool {
        pendingSubmissions > 0 || transfers.contains { $0.state == .waiting || $0.state == .transferring }
    }

    func mayTerminateForUpdate() async -> Bool {
        guard pendingSubmissions == 0 else { return false }
        let checkedEngine = engine
        if let checkedEngine, await checkedEngine.hasPendingTransfers() { return false }
        // Actor state is authoritative: the UI history may lag behind progress.
        // Recheck submissions and engine identity after crossing the actor boundary.
        return pendingSubmissions == 0 && engine === checkedEngine
    }

    var hasFinishedTransferRecords: Bool {
        transfers.contains { $0.state == .completed || $0.state == .failed }
    }

    func removeTransferRecord(id: UUID) {
        transfers.removeAll {
            $0.id == id && ($0.state == .completed || $0.state == .failed)
        }
    }

    func clearFinishedTransferRecords() {
        transfers.removeAll { $0.state == .completed || $0.state == .failed }
    }

    init() {
        let defaults = UserDefaults.standard
        let identifier = defaults.string(forKey: "deviceID").flatMap(UUID.init(uuidString:)) ?? UUID()
        deviceID = identifier
        defaults.set(identifier.uuidString, forKey: "deviceID")
        deviceName = defaults.string(forKey: "deviceName") ?? Host.current().localizedName ?? "我的 Mac"
        selectedPeerID = defaults.string(forKey: "selectedPeerID").flatMap(UUID.init(uuidString:))
        launchAtLogin = defaults.object(forKey: "launchAtLogin") as? Bool ?? true
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true)
        receiveDirectory = downloads.appendingPathComponent("局域快传", isDirectory: true)
        updater.hasPendingTransfers = { [weak self] in self?.hasPendingTransfers ?? false }
        updater.pendingTransferCheck = { [weak self] in
            guard let self else { return false }
            return !(await self.mayTerminateForUpdate())
        }
        do {
            if let password = try PairingKeychain.load() {
                isConfigured = true
                Task { await start(password: password) }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func setup(name: String, password: String) async {
        guard password.count >= 6, password.utf8.count <= 4096 else {
            errorMessage = "配对密码至少需要 6 个字符，最多 4096 字节。两台 Mac 输入完全相同的密码即可。"
            return
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName.utf8.count <= 120 else {
            errorMessage = "请输入有效的设备名称，长度不要超过 120 字节。"
            return
        }
        do {
            try PairingKeychain.save(password)
            deviceName = trimmedName
            UserDefaults.standard.set(trimmedName, forKey: "deviceName")
            isConfigured = true
            errorMessage = nil
            await start(password: password)
            if Bundle.main.bundleIdentifier == "com.sikefix.landrop" {
                _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func start(password: String) async {
        let currentLifecycle = lifecycle
        networkReady = false
        statusText = "正在启动局域网发现"
        do {
            let newEngine = try TransferEngine(directory: receiveDirectory)
            engine = newEngine
            eventTask?.cancel()
            eventTask = Task { [weak self] in
                for await event in newEngine.events {
                    guard !Task.isCancelled, let self else { break }
                    self.handle(event)
                }
            }
            await newEngine.selectPeer(selectedPeerID)
            try await newEngine.start(deviceID: deviceID, name: deviceName, password: password)
            guard currentLifecycle == lifecycle, isConfigured else {
                await newEngine.stop()
                return
            }
            networkReady = true
        } catch {
            guard currentLifecycle == lifecycle, isConfigured else { return }
            errorMessage = "启动失败：\(error.localizedDescription)"
            statusText = "局域网服务暂时不可用"
            let oldEngine = engine
            engine = nil
            await oldEngine?.stop()
            retryTask?.cancel()
            retryTask = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 5_000_000_000) } catch { return }
                guard let self, self.lifecycle == currentLifecycle, self.isConfigured else { return }
                await self.start(password: password)
            }
        }
    }

    private func handle(_ event: TransferEvent) {
        switch event {
        case .peers(let updated):
            peers = updated
            // With two Macs, discovery chooses the only connected recipient automatically.
            if updated.count == 1, let onlyPeer = updated.first {
                selectedPeerID = onlyPeer.id
            } else if selectedPeerID == nil, let first = updated.first {
                selectedPeerID = first.id
            }
        case .status(let text):
            statusText = text
        case .error(let text):
            errorMessage = text
        case .progress(let progress):
            let previous = transfers.first { $0.id == progress.id }?.state
            if let index = transfers.firstIndex(where: { $0.id == progress.id }) {
                transfers[index] = progress
            } else {
                transfers.insert(progress, at: 0)
            }
            if transfers.count > 100 {
                if let oldestFinished = transfers.lastIndex(where: { $0.state == .completed || $0.state == .failed }) {
                    transfers.remove(at: oldestFinished)
                }
            }
            if progress.state == .completed, previous != .completed {
                notifyCompletion(progress)
            }
            updater.transferActivityDidChange()
        }
    }

    func receiveURLs(_ urls: [URL]) {
        guard !updater.isInstallingUpdate else {
            errorMessage = "正在安装新版，完成后即可继续拖入文件。"
            return
        }
        guard isConfigured else {
            errorMessage = "先输入一次配对密码，就可以开始拖放文件。"
            return
        }
        guard networkReady else {
            errorMessage = "局域网服务正在启动，请稍后拖入文件。"
            return
        }
        pendingSubmissions += 1
        updater.transferActivityDidChange()
        Task {
            await engine?.enqueue(urls)
            pendingSubmissions -= 1
            updater.transferActivityDidChange()
        }
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.prompt = "发送"
        panel.message = "选择要发送给另一台 Mac 的文件或文件夹"
        panel.begin { [weak self] response in
            guard response == .OK else { return }
            Task { @MainActor in self?.receiveURLs(panel.urls) }
        }
    }

    func revealDownloads() {
        do {
            try FileManager.default.createDirectory(at: receiveDirectory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(receiveDirectory)
        } catch { errorMessage = error.localizedDescription }
    }

    func resetPairing() {
        do {
            try PairingKeychain.delete()
            lifecycle = UUID()
            retryTask?.cancel()
            retryTask = nil
            eventTask?.cancel()
            eventTask = nil
            let oldEngine = engine
            engine = nil
            Task { await oldEngine?.stop() }
            isConfigured = false
            networkReady = false
            peers = []
            selectedPeerID = nil
            transfers = []
            errorMessage = nil
            statusText = "输入一次密码，之后直接拖放"
            updater.transferActivityDidChange()
        } catch { errorMessage = error.localizedDescription }
    }

    func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            }
            launchAtLogin = enabled
            UserDefaults.standard.set(enabled, forKey: "launchAtLogin")
            if enabled, SMAppService.mainApp.status == .requiresApproval {
                errorMessage = "macOS 要求允许后台启动。请在「系统设置 → 通用 → 登录项」中允许局域快传，之后即可自动运行。"
            }
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            UserDefaults.standard.set(launchAtLogin, forKey: "launchAtLogin")
            errorMessage = "设置开机启动失败：\(error.localizedDescription)"
        }
    }

    private func notifyCompletion(_ progress: TransferProgress) {
        guard Bundle.main.bundleIdentifier == "com.sikefix.landrop" else { return }
        let content = UNMutableNotificationContent()
        content.title = progress.direction == .receiving ? "文件已自动接收" : "文件已送达"
        content.body = "\(progress.filename) · \(progress.peerName)"
        let request = UNNotificationRequest(identifier: progress.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}

private enum PairingKeychain {
    private static let service = "com.sikefix.landrop.pairing"
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "shared-password"]
    }
    static func load() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else { throw KeychainError(status: status) }
        return password
    }
    static func save(_ password: String) throws {
        let data = Data(password.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess { throw KeychainError(status: status) }
    }
    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
    private struct KeychainError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "无法保存或读取配对密码：\(SecCopyErrorMessageString(status, nil) as String? ?? "钥匙串错误 \(status)")"
        }
    }
}
