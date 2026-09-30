import AppKit
import Combine
import SwiftUI

@MainActor
final class MenuBarController: NSObject {
    private let model: AppModel
    private let showWindow: () -> Void
    private let statusItem: NSStatusItem
    private let dropView: MenuBarDropView
    private let dragHint = NSPopover()
    private var subscriptions = Set<AnyCancellable>()

    init(model: AppModel, showWindow: @escaping () -> Void) {
        self.model = model
        self.showWindow = showWindow
        statusItem = NSStatusBar.system.statusItem(withLength: 34)
        dropView = MenuBarDropView(frame: NSRect(x: 0, y: 0, width: 34, height: NSStatusBar.system.thickness))
        super.init()

        if let button = statusItem.button {
            button.title = ""
            dropView.frame = button.bounds
            dropView.autoresizingMask = [.width, .height]
            button.addSubview(dropView)
        }
        dropView.onClick = showWindow
        dropView.onDrop = { [weak self] urls in self?.model.receiveURLs(urls) }
        dropView.onRightClick = { [weak self] event in self?.showMenu(event: event) }
        dropView.onDragHover = { [weak self] hovering in self?.updateDragHint(hovering) }
        dropView.registerForDraggedTypes([.fileURL])
        dropView.setAccessibilityLabel("局域快传。拖入文件发送，点击打开窗口。")
        dragHint.behavior = .transient
        dragHint.animates = false
        dragHint.contentSize = NSSize(width: 240, height: 85)

        model.$peers.map { !$0.isEmpty }
            .combineLatest(model.$isConfigured)
            .sink { [weak self] connected, configured in
                self?.dropView.setConnection(connected: connected, configured: configured)
            }
            .store(in: &subscriptions)
    }

    private func updateDragHint(_ hovering: Bool) {
        guard hovering, let button = statusItem.button else {
            dragHint.performClose(nil)
            return
        }
        let peer = model.peers.first(where: { $0.id == model.selectedPeerID }) ?? model.peers.first
        let title = !model.isConfigured ? "先完成一次配对" : peer == nil ? "松开加入待发送" : "松开鼠标，立即发送"
        let detail = !model.isConfigured ? "点击图标，输入公共配对密码" : peer.map { "发送至 \($0.name) · 自动接收" } ?? "另一台 Mac 连接后自动传输"
        dragHint.contentViewController = NSHostingController(rootView: MenuBarDragHint(title: title, detail: detail))
        dragHint.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func showMenu(event: NSEvent) {
        let menu = NSMenu()
        let title = NSMenuItem(title: "局域快传", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)
        menu.addItem(.separator())
        menu.addItem(menuItem("打开窗口", action: #selector(openWindow)))
        menu.addItem(menuItem("打开接收文件夹", action: #selector(openReceiveFolder)))
        menu.addItem(.separator())
        menu.addItem(menuItem("退出局域快传", action: #selector(quitApp), key: "q"))
        NSMenu.popUpContextMenu(menu, with: event, for: dropView)
    }

    private func menuItem(_ title: String, action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openWindow() { showWindow() }
    @objc private func openReceiveFolder() { model.revealDownloads() }
    @objc private func quitApp() { NSApp.terminate(nil) }
}

@MainActor
private final class MenuBarDropView: NSView {
    var onClick: (() -> Void)?
    var onDrop: (([URL]) -> Void)?
    var onRightClick: ((NSEvent) -> Void)?
    var onDragHover: ((Bool) -> Void)?
    private let imageView = NoninteractiveImageView()
    private let dot = NoninteractiveDotView()
    private var dragHover = false
    private var mouseHover = false
    private var connected = false
    private var configured = false
    private var hoverTrackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 5
        imageView.image = NSImage(systemSymbolName: "arrow.up.arrow.down", accessibilityDescription: "局域快传")
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        imageView.imageScaling = .scaleProportionallyDown
        imageView.contentTintColor = .labelColor
        addSubview(imageView)
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 2.5
        addSubview(dot)
        refreshAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        imageView.frame = NSRect(x: (bounds.width - 18) / 2, y: (bounds.height - 18) / 2, width: 18, height: 18)
        dot.frame = NSRect(x: bounds.maxX - 8, y: 3, width: 5, height: 5)
    }

    func setConnection(connected: Bool, configured: Bool) {
        self.connected = connected
        self.configured = configured
        toolTip = configured
            ? (connected ? "局域快传 · 已连接\n拖入文件立即发送；点击打开窗口" : "局域快传 · 等待另一台 Mac\n拖入文件加入待发送；点击打开窗口")
            : "局域快传 · 点击完成首次配对"
        refreshAppearance()
    }

    private func refreshAppearance() {
        let teal = NSColor(calibratedRed: 0.05, green: 0.47, blue: 0.40, alpha: 1)
        layer?.backgroundColor = (dragHover ? teal.withAlphaComponent(0.2) : mouseHover ? NSColor.labelColor.withAlphaComponent(0.09) : .clear).cgColor
        imageView.contentTintColor = dragHover ? teal : .labelColor
        imageView.image = NSImage(systemSymbolName: dragHover ? "arrow.down.doc.fill" : "arrow.up.arrow.down", accessibilityDescription: "局域快传")
        dot.isHidden = !configured || dragHover
        dot.layer?.backgroundColor = (connected ? teal : NSColor.secondaryLabelColor).cgColor
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { mouseHover = true; refreshAppearance() }
    override func mouseExited(with event: NSEvent) { mouseHover = false; refreshAppearance() }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            onRightClick?(event)
        } else {
            onClick?()
        }
    }

    override func rightMouseDown(with event: NSEvent) { onRightClick?(event) }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard !fileURLs(from: sender.draggingPasteboard).isEmpty else { return [] }
        dragHover = true
        refreshAppearance()
        onDragHover?(true)
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dragHover = false
        refreshAppearance()
        onDragHover?(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dragHover = false
        refreshAppearance()
        onDragHover?(false)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        !fileURLs(from: sender.draggingPasteboard).isEmpty
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = fileURLs(from: sender.draggingPasteboard)
        dragHover = false
        refreshAppearance()
        onDragHover?(false)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        if !configured { onClick?() }
        return true
    }
}

private final class NoninteractiveImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class NoninteractiveDotView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private struct MenuBarDragHint: View {
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 11) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 23, weight: .regular))
                .foregroundStyle(Color(red: 0.05, green: 0.47, blue: 0.40))
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(17)
        .frame(width: 240, height: 85, alignment: .leading)
    }
}
