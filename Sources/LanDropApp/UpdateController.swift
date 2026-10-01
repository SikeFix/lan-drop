import AppKit
import Combine
import Foundation
import Sparkle

/// Sparkle owns its persisted preferences and update schedule. The application
/// controls only when a prepared update may interrupt the transfer queue.
@MainActor
final class UpdateController: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var statusText = "正在准备自动更新"
    @Published private(set) var automaticUpdatesEnabled = true
    @Published private(set) var canInstallUpdatesAutomatically = false
    @Published private(set) var isInstallingUpdate = false

    var hasPendingTransfers: () -> Bool = { false } {
        didSet { transferActivityDidChange() }
    }
    var pendingTransferCheck: (() async -> Bool)?

    var isWaitingToInstall: Bool {
        (pendingInstallation != nil || manualRetryAwaitingTermination) && !isInstallingUpdate
    }

    private enum InstallationKind { case automatic, relaunch }
    private struct PendingInstallation {
        let id = UUID()
        let kind: InstallationKind
        let handler: () -> Void
    }

    private var controller: SPUStandardUpdaterController?
    private var observations = Set<AnyCancellable>()
    private var pendingInstallation: PendingInstallation?
    private var automaticInstallHandler: (() -> Void)?
    // Sparkle's standard UI retains its own retry-termination callback after a
    // manual restart is vetoed. Keep the final application guard active even
    // though our one-shot postponed-relaunch callback has already been invoked.
    private var manualRetryAwaitingTermination = false
    private var idleMonitor: Task<Void, Never>?
    private var idleMonitorID = UUID()
    private var availableVersion: String?

    override init() {
        super.init()
        let bundle = Bundle.main
        guard bundle.bundleURL.pathExtension == "app",
              bundle.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "APPL" else {
            automaticUpdatesEnabled = false
            statusText = "开发运行版本不支持自动更新，请打开打包后的应用。"
            return
        }
        guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              let feedURL = URL(string: feed), feedURL.scheme == "https", feedURL.host != nil,
              let publicKey = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              Data(base64Encoded: publicKey)?.count == 32 else {
            automaticUpdatesEnabled = false
            statusText = "此版本尚未配置安全的自动更新源。"
            return
        }

        let controller = SPUStandardUpdaterController(
            startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil
        )
        self.controller = controller
        let updater = controller.updater
        updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshAvailability() }
            .store(in: &observations)
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshAvailability() }
            .store(in: &observations)
        updater.publisher(for: \.automaticallyDownloadsUpdates)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshAvailability() }
            .store(in: &observations)
        do {
            // Calling the updater directly lets configuration errors stay in the
            // settings status instead of showing the standard controller's alert.
            try updater.start()
            refreshAvailability()
            statusText = automaticUpdatesEnabled ? "自动检查并下载新版本，空闲时安装。" : "自动更新已关闭，可手动检查。"
        } catch {
            observations.removeAll()
            self.controller = nil
            automaticUpdatesEnabled = false
            statusText = "自动更新启动失败：\(error.localizedDescription)"
        }
    }

    deinit { idleMonitor?.cancel() }

    func checkForUpdates() {
        guard canCheckForUpdates, let controller else { return }
        statusText = manualRetryAwaitingTermination
            ? "更新已准备好，可在更新窗口中继续安装。"
            : "正在检查 GitHub 新版本…"
        controller.checkForUpdates(nil)
    }

    func setAutomaticUpdatesEnabled(_ enabled: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = enabled
        updater.automaticallyDownloadsUpdates = enabled && updater.allowsAutomaticUpdates
        refreshAvailability()
        statusText = automaticUpdatesEnabled ? "自动检查并下载新版本，空闲时安装。" : "自动更新已关闭，可手动检查。"
        transferActivityDidChange()
    }

    /// Called after queue/progress changes. A monitor also covers gaps between
    /// events, so a prepared update does not depend on a final progress callback.
    func transferActivityDidChange() {
        guard pendingInstallation != nil else { return }
        if hasPendingTransfers() {
            statusText = "更新已准备好，等待文件传输和发送队列完成。"
        }
        startIdleMonitorIfNeeded()
    }

    /// The final application-termination guard can discover new transfers after
    /// Sparkle requested a restart. Automatic installation is then tried again
    /// only after the queue becomes idle; Sparkle permits reusing this handler.
    func installationWasDeferred() {
        isInstallingUpdate = false
        if pendingInstallation == nil, let automaticInstallHandler {
            pendingInstallation = PendingInstallation(kind: .automatic, handler: automaticInstallHandler)
        }
        manualRetryAwaitingTermination = pendingInstallation == nil
        statusText = manualRetryAwaitingTermination
            ? "已暂缓更新，请在传输完成后点击「检查更新」继续安装。"
            : "已暂缓更新，正在等待文件传输完成。"
        refreshAvailability()
        transferActivityDidChange()
    }

    private func refreshAvailability() {
        guard let updater = controller?.updater else {
            canCheckForUpdates = false
            canInstallUpdatesAutomatically = false
            return
        }
        canCheckForUpdates = updater.canCheckForUpdates && !isInstallingUpdate
        canInstallUpdatesAutomatically = updater.allowsAutomaticUpdates
        automaticUpdatesEnabled = updater.automaticallyChecksForUpdates && updater.automaticallyDownloadsUpdates
    }

    private func startIdleMonitorIfNeeded() {
        guard idleMonitor == nil, pendingInstallation != nil, !isInstallingUpdate else { return }
        let monitorID = UUID()
        idleMonitorID = monitorID
        idleMonitor = Task { [weak self] in
            // Let the delegate return before invoking any installation callback,
            // and leave a brief quiet period for queued drag/drop events to arrive.
            var idleSince: Date?
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
                guard let self, let pending = self.pendingInstallation, !self.isInstallingUpdate else { break }
                let queueIsBusy = await self.transferQueueIsBusy()
                guard !Task.isCancelled, self.idleMonitorID == monitorID else { break }
                // The actor check yields the main actor. A cycle may finish, a
                // different callback may be installed, or settings may change
                // during that wait; never invoke the old callback afterward.
                guard self.pendingInstallation?.id == pending.id, !self.isInstallingUpdate else {
                    idleSince = nil
                    continue
                }
                if pending.kind == .automatic && !self.automaticUpdatesEnabled {
                    self.statusText = "更新已下载，将在退出应用时安装。"
                    break
                }
                if queueIsBusy {
                    idleSince = nil
                    self.statusText = "更新已准备好，等待文件传输和发送队列完成。"
                    continue
                }
                if let idleSince, Date().timeIntervalSince(idleSince) >= 2 {
                    self.pendingInstallation = nil
                    self.isInstallingUpdate = true
                    self.statusText = "正在安装更新，应用将自动重新打开。"
                    self.refreshAvailability()
                    pending.handler()
                    break
                }
                if idleSince == nil { idleSince = Date() }
            }
            if self?.idleMonitorID == monitorID { self?.idleMonitor = nil }
        }
    }

    private func transferQueueIsBusy() async -> Bool {
        if let pendingTransferCheck { return await pendingTransferCheck() }
        return hasPendingTransfers()
    }

    private func clearInstallationState() {
        idleMonitor?.cancel()
        idleMonitor = nil
        idleMonitorID = UUID()
        pendingInstallation = nil
        automaticInstallHandler = nil
        manualRetryAwaitingTermination = false
        isInstallingUpdate = false
        refreshAvailability()
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool { false }

    func allowedSystemProfileKeys(for updater: SPUUpdater) -> [String]? { [] }

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        availableVersion = item.displayVersionString
        statusText = "发现新版本 \(item.displayVersionString)，正在准备更新。"
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        availableVersion = nil
        statusText = "当前已是最新版本。"
    }

    func updater(_ updater: SPUUpdater, didDownloadUpdate item: SUAppcastItem) {
        statusText = "新版本已下载，正在校验并准备安装。"
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        isInstallingUpdate = true
        statusText = "正在安装更新，应用将自动重新打开。"
        refreshAvailability()
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        guard hasPendingTransfers() else {
            isInstallingUpdate = true
            refreshAvailability()
            return false
        }
        isInstallingUpdate = false
        manualRetryAwaitingTermination = false
        pendingInstallation = PendingInstallation(kind: .relaunch, handler: installHandler)
        transferActivityDidChange()
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        automaticInstallHandler = immediateInstallHandler
        manualRetryAwaitingTermination = false
        pendingInstallation = PendingInstallation(kind: .automatic, handler: immediateInstallHandler)
        statusText = "更新已准备好，空闲时自动安装。"
        transferActivityDidChange()
        return true
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        // A termination veto leaves the cycle/driver alive and does not call this
        // delegate. SUInstallationCanceledError instead means the installer
        // authorization was cancelled. When a cycle finishes for any reason,
        // Sparkle disposes the driver captured weakly by installation handlers;
        // retaining them would schedule callbacks that can no longer install.
        clearInstallationState()
        if let error {
            let nsError = error as NSError
            if nsError.domain == SUSparkleErrorDomain, nsError.code == Int(SUError.noUpdateError.rawValue) {
                statusText = "当前已是最新版本。"
            } else if nsError.domain == SUSparkleErrorDomain,
                      nsError.code == Int(SUError.installationCanceledError.rawValue) {
                statusText = "更新安装已取消，可稍后重新检查。"
            } else {
                // The standard driver already presents errors for a user-requested
                // check. Background failures only update this quiet settings text.
                statusText = updater.automaticallyChecksForUpdates
                    ? "暂时无法检查更新，稍后会自动重试。"
                    : "暂时无法检查更新，请稍后重新检查。"
            }
        } else {
            if let availableVersion {
                statusText = "新版本 \(availableVersion) 可用，可点击「检查更新」查看。"
            }
        }
        refreshAvailability()
    }
}
