import AppKit
import Combine
import SwiftUI

final class TerminalTabSidebarModel: ObservableObject {
    static let didChange = Notification.Name("TerminalTabSidebarDidChange")

    struct Tab: Identifiable, Equatable {
        let id: ObjectIdentifier
        weak var window: TerminalWindow?
        let title: String
        let number: Int
        let color: NSColor?
        let hasBell: Bool
        let isZoomed: Bool
        let revealState: TerminalTabSidebarRevealState
    }

    struct Drag {
        let id: ObjectIdentifier
        let sourceIndex: Int
        var position: CGFloat

        var destinationIndex: Int {
            Int((position / TerminalTabSidebarLayout.stride).rounded())
        }
    }

    @Published private(set) var tabs: [Tab] = []
    @Published private(set) var drag: Drag?
    @Published private(set) var selectedID: ObjectIdentifier?
    @Published private(set) var topInset: CGFloat = 26
    @Published private(set) var isVisible = true
    var isTransitioningFullscreen = false

    private weak var group: NSWindowTabGroup?
    private weak var standaloneWindow: TerminalWindow?
    private var groupObservations: [NSKeyValueObservation] = []
    private var titleObservations: [NSKeyValueObservation] = []
    private var notifications: [NSObjectProtocol] = []
    private var refreshPending = false

    private var windows: [TerminalWindow] {
        group?.windows.compactMap { $0 as? TerminalWindow } ?? [standaloneWindow].compactMap { $0 }
    }

    private var window: TerminalWindow? {
        group?.selectedWindow as? TerminalWindow ?? windows.first
    }

    init(window: TerminalWindow) {
        group = window.tabGroup
        if let group {
            groupObservations = [
                group.observe(\.windows) { [weak self] _, _ in self?.scheduleRefresh() },
                group.observe(\.selectedWindow) { [weak self] _, _ in self?.scheduleRefresh() },
            ]
        } else {
            standaloneWindow = window
        }
        for name in [Self.didChange, NSWindow.didBecomeKeyNotification,
                     NSWindow.willCloseNotification, NSWindow.didEnterFullScreenNotification,
                     NSWindow.didExitFullScreenNotification, .terminalWindowBellDidChangeNotification] {
            notifications.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] notification in
                guard let self,
                      let source = notification.object as? NSWindow ??
                        (notification.object as? NSWindowController)?.window,
                      self.windows.contains(where: { $0 === source }) else { return }
                self.scheduleRefresh()
            })
        }
        refresh()
    }

    deinit {
        notifications.forEach(NotificationCenter.default.removeObserver)
    }

    private func scheduleRefresh() {
        guard !refreshPending else { return }
        refreshPending = true
        DispatchQueue.main.async { [weak self] in
            self?.refreshPending = false
            self?.refresh()
        }
    }

    func refresh() {
        let windows = self.windows
        if tabs.map(\.id) != windows.map(ObjectIdentifier.init) {
            cancelDrag()
            titleObservations = windows.map { window in
                window.observe(\.title) { [weak self] _, _ in self?.scheduleRefresh() }
            }
        }
        let updatedTabs = windows.enumerated().map { index, window in
            Tab(
                id: ObjectIdentifier(window),
                window: window,
                title: title(for: window),
                number: index + 1,
                color: window.tabColor.displayColor,
                hasBell: window.terminalController?.bell ?? false,
                isZoomed: window.surfaceIsZoomed,
                revealState: window.tabSidebarRevealState
            )
        }
        if tabs != updatedTabs { tabs = updatedTabs }
        let window = self.window
        let updatedSelection = window.map(ObjectIdentifier.init)
        if selectedID != updatedSelection { selectedID = updatedSelection }
        if !isTransitioningFullscreen {
            setTopInset(fullscreen: window?.styleMask.contains(.fullScreen) == true)
        }
        window?.hideNativeTabBarForSidebar()
    }

    func setTopInset(fullscreen: Bool) {
        let hasButtons = window?.styleMask.contains(.titled) == true &&
            window?.derivedConfig.macosWindowButtons != .hidden
        let inset: CGFloat = !fullscreen && hasButtons ? 26 : 6
        if topInset != inset { topInset = inset }
    }

    func toggleVisibility() {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            isVisible.toggle()
        }
    }

    private func title(for window: TerminalWindow) -> String {
        if let controller = window.terminalController,
           controller.titleOverride == nil,
           controller.focusedSurface?.hasResolvedTitle != true {
            return ""
        }
        return window.title
    }

    func select(_ tab: Tab) {
        guard let window = tab.window else { return }
        window.makeKeyAndOrderFront(nil)
        if let controller = window.terminalController,
           let surface = controller.focusedSurface {
            controller.focusSurface(surface)
        }
    }

    func close(_ tab: Tab) {
        tab.window?.terminalController?.closeTab(nil)
    }

    func newTab() {
        window?.terminalController?.newWindowForTab(nil)
    }

    @discardableResult
    func beginDrag(_ id: ObjectIdentifier) -> Bool {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        drag = Drag(id: id, sourceIndex: index, position: CGFloat(index) * TerminalTabSidebarLayout.stride)
        return true
    }

    func updateDrag(offset: CGFloat) {
        guard var drag else { return }
        let stride = TerminalTabSidebarLayout.stride
        let position = (CGFloat(drag.sourceIndex) * stride + offset).clamped(to: 0...(CGFloat(tabs.count - 1) * stride))
        guard position != drag.position else { return }
        drag.position = position
        self.drag = drag
    }

    func position(for tab: Tab) -> CGFloat {
        let index = tab.number - 1
        let stride = TerminalTabSidebarLayout.stride
        guard let drag else { return CGFloat(index) * stride }
        if tab.id == drag.id { return drag.position }
        if index > drag.sourceIndex && index <= drag.destinationIndex { return CGFloat(index - 1) * stride }
        if index < drag.sourceIndex && index >= drag.destinationIndex { return CGFloat(index + 1) * stride }
        return CGFloat(index) * stride
    }

    func finishDrag() {
        guard let drag else { return }
        move(drag.id, to: tabs[drag.destinationIndex].id)
        cancelDrag()
    }

    func cancelDrag() {
        if drag != nil { drag = nil }
    }

    func move(_ sourceID: ObjectIdentifier, to destinationID: ObjectIdentifier) {
        guard sourceID != destinationID,
              let source = tabs.first(where: { $0.id == sourceID })?.window,
              let destination = tabs.first(where: { $0.id == destinationID })?.window,
              let group,
              source.tabGroup === group, destination.tabGroup === group,
              let destinationIndex = group.windows.firstIndex(of: destination) else { return }
        let selectedWindow = group.selectedWindow
        group.insertWindow(source, at: destinationIndex)
        group.selectedWindow = selectedWindow
        window?.terminalController?.relabelTabs()
        refresh()
    }
}

final class TerminalTabSidebarRevealState: ObservableObject, Equatable {
    @Published private(set) var isRevealed = false

    static func == (lhs: TerminalTabSidebarRevealState, rhs: TerminalTabSidebarRevealState) -> Bool {
        lhs === rhs
    }

    func reveal() {
        guard !isRevealed else { return }
        isRevealed = true
    }
}

final class TerminalTabSidebarPresentation {
    private static var associationKey: UInt8 = 0
    let model: TerminalTabSidebarModel
    private let sidebarView: TerminalTabSidebarContentView
    // Fullscreen can be entered and exited from different native tab windows.
    private(set) var windowedFrame: NSRect?
    private var isFullscreen: Bool
    private var fullscreenTransition: (window: ObjectIdentifier, frame: NSRect, entering: Bool)?
    private var hiddenTitlebars: [(view: NSView, alpha: CGFloat)] = []

    var view: NSView { sidebarView }

    private init(window: TerminalWindow) {
        isFullscreen = window.styleMask.contains(.fullScreen)
        model = TerminalTabSidebarModel(window: window)
        sidebarView = TerminalTabSidebarContentView(model: model)
        sidebarView.autoresizingMask = [.width, .height]
    }

    static func shared(for window: TerminalWindow) -> TerminalTabSidebarPresentation {
        let owner = (window.tabGroup as AnyObject?) ?? window
        if let existing = objc_getAssociatedObject(owner, &associationKey) as? TerminalTabSidebarPresentation {
            return existing
        }
        let presentation = TerminalTabSidebarPresentation(window: window)
        objc_setAssociatedObject(owner, &associationKey, presentation, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return presentation
    }

    func present(in slot: TerminalTabSidebarSlotView) {
        model.refresh()
        slot.bind(to: model)
        if sidebarView.superview !== slot {
            // Native tabs swap entire windows; keep the rendered sidebar and its scroll state alive.
            slot.subviews.forEach { $0.removeFromSuperview() }
            sidebarView.removeFromSuperview()
            sidebarView.frame = slot.bounds
            slot.addSubview(sidebarView)
        }
        sidebarView.layoutSubtreeIfNeeded()
    }

    @discardableResult
    func beginFullscreenTransition(for window: TerminalWindow, entering: Bool) -> Bool {
        if let transition = fullscreenTransition { return transition.window == ObjectIdentifier(window) }
        guard entering != isFullscreen else { return false }
        fullscreenTransition = (ObjectIdentifier(window), window.frame, entering)
        if entering { windowedFrame = window.frame }
        model.isTransitioningFullscreen = true
        hideTitlebar(for: window)
        sidebarView.layoutSubtreeIfNeeded()
        return true
    }

    func animateFullscreenTransition(for window: TerminalWindow, to frame: NSRect, duration: TimeInterval) {
        guard let transition = fullscreenTransition, transition.window == ObjectIdentifier(window) else { return }
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        hideTitlebar(for: window)
        let previousInset = model.topInset
        withAnimation(reduceMotion ? nil : .easeInOut(duration: duration)) {
            model.setTopInset(fullscreen: transition.entering)
        }
        sidebarView.animateTopInset(from: previousInset, duration: reduceMotion ? 0 : duration)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0 : duration
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }
    }

    func finishFullscreenTransition(for window: TerminalWindow, failed: Bool = false) {
        guard let transition = fullscreenTransition, transition.window == ObjectIdentifier(window) else { return }
        if failed { window.setFrame(transition.frame, display: true) }
        isFullscreen = failed ? !transition.entering : window.styleMask.contains(.fullScreen)
        fullscreenTransition = nil
        model.isTransitioningFullscreen = false
        sidebarView.finishInsetAnimation()
        model.refresh()
        for (titlebar, alpha) in hiddenTitlebars { titlebar.alphaValue = alpha }
        hiddenTitlebars.removeAll()
    }

    private func hideTitlebar(for window: TerminalWindow) {
        guard let titlebar = window.titlebarContainer,
              !hiddenTitlebars.contains(where: { $0.view === titlebar }) else { return }
        hiddenTitlebars.append((titlebar, titlebar.alphaValue))
        titlebar.alphaValue = 0
    }
}

private final class TerminalTabSidebarContentView: NSView {
    private let hostingView: NSHostingView<TerminalTabSidebar>
    private var topConstraint: NSLayoutConstraint!
    private var insetObservation: AnyCancellable?

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }

    init(model: TerminalTabSidebarModel) {
        hostingView = NSHostingView(rootView: TerminalTabSidebar(model: model))
        super.init(frame: .zero)
        wantsLayer = true
        clipsToBounds = true
        hostingView.sizingOptions = []
        hostingView.wantsLayer = true
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostingView)
        let dragArea = TerminalTabSidebarWindowDragView()
        dragArea.translatesAutoresizingMaskIntoConstraints = false
        addSubview(dragArea)
        topConstraint = hostingView.topAnchor.constraint(equalTo: topAnchor, constant: model.topInset)
        NSLayoutConstraint.activate([
            topConstraint,
            hostingView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostingView.bottomAnchor.constraint(equalTo: bottomAnchor),
            dragArea.topAnchor.constraint(equalTo: topAnchor),
            dragArea.leadingAnchor.constraint(equalTo: leadingAnchor),
            dragArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            dragArea.bottomAnchor.constraint(equalTo: hostingView.topAnchor),
        ])
        insetObservation = model.$topInset.removeDuplicates().sink { [weak self] inset in
            self?.setTopInset(inset)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.95).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func setTopInset(_ inset: CGFloat) {
        guard topConstraint.constant != inset else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0
            context.allowsImplicitAnimation = false
            topConstraint.constant = inset
            layoutSubtreeIfNeeded()
        }
    }

    func animateTopInset(from previousInset: CGFloat, duration: TimeInterval) {
        guard duration > 0, previousInset != topConstraint.constant else { return }
        // A translation leaves the sidebar background and viewport resizing with the native window.
        let animation = CABasicAnimation(keyPath: "transform.translation.y")
        animation.fromValue = previousInset - topConstraint.constant
        animation.toValue = 0
        animation.duration = duration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        hostingView.layer?.add(animation, forKey: "fullscreenInset")
    }

    func finishInsetAnimation() {
        hostingView.layer?.removeAnimation(forKey: "fullscreenInset")
    }
}

final class TerminalTabSidebarSlotView: NSView, ObservableObject {
    @Published private(set) var isSidebarVisible = true
    @Published private(set) var topInset: CGFloat = 26
    private weak var model: TerminalTabSidebarModel?
    private var observation: AnyCancellable?

    func bind(to model: TerminalTabSidebarModel) {
        guard self.model !== model else { return }
        self.model = model
        observation = model.$isVisible.combineLatest(model.$topInset).sink { [weak self] visible, inset in
            guard let self else { return }
            if self.isSidebarVisible != visible { self.isSidebarVisible = visible }
            if self.topInset != inset { self.topInset = inset }
        }
    }
}

private struct TerminalTabSidebarSlot: NSViewRepresentable {
    let view: NSView

    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ view: NSView, context: Context) {}
}

struct TerminalSidebarContainer<Content: View>: View {
    @ObservedObject var sidebar: TerminalTabSidebarSlotView
    @AppStorage(TerminalTabSidebarLayout.widthKey) private var sidebarWidth = TerminalTabSidebarLayout.defaultWidth
    @State private var dragWidth: Double?
    @ViewBuilder let content: () -> Content

    private var width: Double {
        sidebarWidth.clamped(to: TerminalTabSidebarLayout.widthRange)
    }

    var body: some View {
        HStack(spacing: 0) {
            sidebarPanel
                .frame(width: width + 1)
                .offset(x: sidebar.isSidebarVisible ? 0 : -(width + 1))
                .frame(width: sidebar.isSidebarVisible ? width + 1 : 0, alignment: .leading)
                .clipped()
                .allowsHitTesting(sidebar.isSidebarVisible)
                .accessibilityHidden(!sidebar.isSidebarVisible)
            content()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(TerminalTabSidebarLayout.contentPadding)
                .padding(.top, sidebar.isSidebarVisible ? 0 :
                    max(0, sidebar.topInset - TerminalTabSidebarLayout.contentPadding))
        }
        .ignoresSafeArea(.container, edges: .top)
    }

    private var sidebarPanel: some View {
        HStack(spacing: 0) {
            TerminalTabSidebarSlot(view: sidebar)
                .frame(width: width)
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.6))
                .frame(width: 1)
                .overlay {
                    Color.clear
                        .frame(width: 7)
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .global)
                            .onChanged { value in
                                if dragWidth == nil { dragWidth = width }
                                sidebarWidth = ((dragWidth ?? width) + value.translation.width)
                                    .clamped(to: TerminalTabSidebarLayout.widthRange)
                            }
                            .onEnded { _ in dragWidth = nil })
                        .backport.pointerStyle(.resizeLeftRight)
                        .onHover { inside in
                            if #available(macOS 15, *) { return }
                            if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                        }
                }
                .accessibilityLabel("Tab sidebar width")
                .accessibilityValue("\(Int(width)) points")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: sidebarWidth = (width + 20).clamped(to: TerminalTabSidebarLayout.widthRange)
                    case .decrement: sidebarWidth = (width - 20).clamped(to: TerminalTabSidebarLayout.widthRange)
                    @unknown default: break
                    }
                }
        }
    }
}

private struct TerminalTabSidebar: View {
    @ObservedObject var model: TerminalTabSidebarModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private struct ScrollTarget: Hashable {
        let id: ObjectIdentifier
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                ZStack(alignment: .top) {
                    // Scroll targets need row-sized bounds, without the positioning padding.
                    VStack(spacing: TerminalTabSidebarLayout.spacing) {
                        ForEach(model.tabs) { tab in
                            Color.clear
                                .frame(height: TerminalTabSidebarLayout.rowHeight)
                                .id(ScrollTarget(id: tab.id))
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    ForEach(model.tabs) { tab in
                        let isDragging = model.drag?.id == tab.id
                        let position = model.position(for: tab)
                        TerminalTabSidebarRow(
                            model: model, tab: tab, selected: model.selectedID == tab.id, isDragging: isDragging
                        )
                        .padding(.top, position)
                        .animation(reduceMotion || isDragging ? nil : .interactiveSpring(
                            response: 0.22, dampingFraction: 0.9
                        ), value: position)
                        .zIndex(isDragging ? 1 : 0)
                    }
                }
                .padding(.bottom, 8)
            }
            .onChange(of: model.selectedID) { id in
                if let id { proxy.scrollTo(ScrollTarget(id: id)) }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .ignoresSafeArea(.container, edges: .top)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Tab sidebar")
    }
}

private struct TerminalTabSidebarRow: View {
    let model: TerminalTabSidebarModel
    let tab: TerminalTabSidebarModel.Tab
    let selected: Bool
    let isDragging: Bool
    @ObservedObject private var revealState: TerminalTabSidebarRevealState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: TerminalTabSidebarModel, tab: TerminalTabSidebarModel.Tab, selected: Bool, isDragging: Bool) {
        self.model = model
        self.tab = tab
        self.selected = selected
        self.isDragging = isDragging
        self.revealState = tab.revealState
    }

    var body: some View {
        Button { model.select(tab) } label: {
            HStack(spacing: 6) {
                Text(String(tab.number))
                    .font(.system(size: selected ? 14 : 12, weight: selected ? .bold : .medium))
                    .monospacedDigit()
                    .foregroundStyle(tab.color.map(Color.init(nsColor:)) ?? (selected ? .primary : .secondary))
                    .frame(width: 24, height: 24)
                    .opacity(revealState.isRevealed ? 1 : 0)
                Text(tab.title)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .opacity(revealState.isRevealed ? 1 : 0)
                Spacer(minLength: 0)
                if tab.hasBell {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .opacity(revealState.isRevealed ? 1 : 0)
                        .accessibilityLabel("Bell alert")
                }
                if tab.isZoomed { Color.clear.frame(width: 16, height: 16) }
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(height: TerminalTabSidebarLayout.rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(tab.title.isEmpty ? "Tab \(tab.number)" : tab.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .overlay {
            TerminalTabDragHandle(tab: tab, model: model)
                .accessibilityHidden(true)
        }
        .overlay(alignment: .trailing) {
            if tab.isZoomed {
                Button { tab.window?.terminalController?.splitZoom(model) } label: {
                    Image("ResetZoom")
                        .resizable()
                        .frame(width: 16, height: 16)
                        .opacity(revealState.isRevealed ? 1 : 0)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 8)
                .help("Reset Split Zoom")
                .accessibilityLabel("Reset Split Zoom")
            }
        }
        .background {
            if isDragging {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: revealState.isRevealed)
        .onAppear {
            if !tab.title.isEmpty { revealState.reveal() }
        }
        .onChange(of: tab.title.isEmpty) { isEmpty in
            if !isEmpty { revealState.reveal() }
        }
        .help(tab.title)
        .contextMenu {
            Button("Rename Tab…") {
                tab.window?.makeKeyAndOrderFront(nil)
                tab.window?.terminalController?.promptTabTitle()
            }
            Menu("Tab Color") {
                ForEach(TerminalTabColor.allCases, id: \.rawValue) { color in
                    Button(color.localizedName) { tab.window?.tabColor = color }
                }
            }
            Divider()
            Button("New Tab", action: model.newTab)
            Button("Close Tab") { model.close(tab) }
        }
    }
}

enum TerminalTabSidebarLayout {
    static let widthKey = "TerminalTabSidebarWidth"
    static let defaultWidth = 210.0
    static let widthRange = 140.0...360.0
    static let contentPadding: CGFloat = 12
    static let rowHeight: CGFloat = 34
    static let spacing: CGFloat = 6
    static let stride = rowHeight + spacing

    static var initialWidth: CGFloat {
        let saved = UserDefaults.standard.double(forKey: widthKey)
        return saved == 0 ? defaultWidth : saved.clamped(to: widthRange)
    }
}

private final class TerminalTabSidebarWindowDragView: NSView {
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

struct TerminalTabDragHandle: NSViewRepresentable {
    let tab: TerminalTabSidebarModel.Tab
    let model: TerminalTabSidebarModel

    func makeNSView(context: Context) -> DragView { DragView() }

    func updateNSView(_ view: DragView, context: Context) {
        view.select = { model.select(tab) }
        view.dragBegan = { model.beginDrag(tab.id) }
        view.dragChanged = { model.updateDrag(offset: $0) }
        view.dragEnded = { model.finishDrag() }
        view.dragCancelled = { model.cancelDrag() }
    }

    final class DragView: NSView {
        var select: (() -> Void)?
        var dragBegan: (() -> Bool)?
        var dragChanged: ((CGFloat) -> Void)?
        var dragEnded: (() -> Void)?
        var dragCancelled: (() -> Void)?
        private var startPoint: NSPoint?
        private var dragging = false
        private var escapeMonitor: Any?

        deinit {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        }

        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func resetCursorRects() {
            addCursorRect(bounds, cursor: dragging ? .closedHand : .openHand)
        }

        override func mouseDown(with event: NSEvent) {
            startPoint = event.locationInWindow
            dragging = false
        }

        override func mouseDragged(with event: NSEvent) {
            guard let startPoint else { return }
            let offset = startPoint.y - event.locationInWindow.y
            guard dragging || abs(offset) > 4 else { return }
            if !dragging {
                guard dragBegan?() == true else { return }
                dragging = true
                NSCursor.closedHand.set()
                escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    guard event.keyCode == 53 else { return event }
                    self?.dragCancelled?()
                    self?.resetDrag()
                    return nil
                }
            }
            dragChanged?(offset)
        }

        override func mouseUp(with event: NSEvent) {
            guard let startPoint else { return }
            if dragging {
                dragChanged?(startPoint.y - event.locationInWindow.y)
                dragEnded?()
            } else {
                select?()
            }
            resetDrag()
        }

        private func resetDrag() {
            if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
            escapeMonitor = nil
            startPoint = nil
            dragging = false
            window?.invalidateCursorRects(for: self)
        }
    }
}
