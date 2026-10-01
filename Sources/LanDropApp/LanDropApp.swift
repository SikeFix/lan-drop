import AppKit
import SwiftUI

@main
struct LanDropApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(LanDropAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("局域快传", id: "main") {
            MainWindowContent(model: model, appDelegate: appDelegate)
                .frame(minWidth: 820, minHeight: 610)
        }
        .defaultSize(width: 900, height: 680)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandGroup(after: .appInfo) {
                CheckForUpdatesCommand(updater: model.updater)
                Divider()
                Button("打开局域快传") { appDelegate.showMainWindow() }
                    .keyboardShortcut("0", modifiers: .command)
                Button("打开接收文件夹") { model.revealDownloads() }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
            }
        }
    }
}

private struct CheckForUpdatesCommand: View {
    @ObservedObject var updater: UpdateController

    var body: some View {
        Button("检查更新…", action: updater.checkForUpdates)
            .disabled(!updater.canCheckForUpdates)
    }
}

private struct MainWindowContent: View {
    @ObservedObject var model: AppModel
    let appDelegate: LanDropAppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView(model: model)
            .background(WindowAttachment { window in
                appDelegate.attachWindow(window)
            })
            .onAppear {
                appDelegate.configure(model: model) { openWindow(id: "main") }
            }
    }
}

@MainActor
final class LanDropAppDelegate: NSObject, NSApplicationDelegate {
    private weak var mainWindow: NSWindow?
    private weak var appModel: AppModel?
    private var menuBarController: MenuBarController?
    private var openMainWindow: (() -> Void)?

    func configure(model: AppModel, openWindow: @escaping () -> Void) {
        appModel = model
        openMainWindow = openWindow
        guard menuBarController == nil else { return }
        menuBarController = MenuBarController(model: model) { [weak self] in
            self?.showMainWindow()
        }
    }

    func attachWindow(_ window: NSWindow) {
        mainWindow = window
        window.identifier = NSUserInterfaceItemIdentifier("LanDropMainWindow")
        window.isMovableByWindowBackground = true
        window.title = "局域快传"
        window.backgroundColor = NSColor(calibratedRed: 0.973, green: 0.973, blue: 0.961, alpha: 1)
    }

    func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainWindow, NSApp.windows.contains(where: { $0 === window }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openMainWindow?()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model = appModel,
              model.updater.isInstallingUpdate || model.updater.isWaitingToInstall else { return .terminateNow }
        Task {
            let allowed = await model.mayTerminateForUpdate()
            if !allowed { model.updater.installationWasDeferred() }
            sender.reply(toApplicationShouldTerminate: allowed)
        }
        return .terminateLater
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }
}

private struct WindowAttachment: NSViewRepresentable {
    let attach: (NSWindow) -> Void

    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.attach = attach
        return view
    }

    func updateNSView(_ nsView: AttachmentView, context: Context) {
        nsView.attach = attach
        if let window = nsView.window { attach(window) }
    }

    final class AttachmentView: NSView {
        var attach: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { attach?(window) }
        }
    }
}
