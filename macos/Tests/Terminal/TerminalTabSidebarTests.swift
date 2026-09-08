import AppKit
import Combine
import SwiftUI
import Testing
@testable import Ghostty

@Suite(.serialized)
@MainActor
struct TerminalTabSidebarTests {
    private func makeWindows(_ titles: [String]) -> [TerminalWindow] {
        let identifier = UUID().uuidString
        let windows = titles.map { title in
            let window = TerminalWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.tabbingIdentifier = identifier
            window.title = title
            return window
        }
        for window in windows.dropFirst() {
            windows[0].addTabbedWindow(window, ordered: .above)
        }
        return windows
    }

    @Test func tracksTitlesSelectionAndClosedTabs() async throws {
        let windows = makeWindows(["First", "Second"])
        defer { windows.forEach { $0.close() } }
        let model = TerminalTabSidebarModel(window: windows[1])
        #expect(model.tabs.map(\.title) == ["First", "Second"])
        #expect(model.tabs.map(\.number) == [1, 2])

        windows[1].title = "Build running"
        windows[0].tabGroup?.selectedWindow = windows[1]
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.tabs.map(\.title) == ["First", "Build running"])
        #expect(model.selectedID == ObjectIdentifier(windows[1]))

        windows[0].close()
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.tabs.map(\.title) == ["Build running"])
        #expect(model.tabs.map(\.number) == [1])
        #expect(model.selectedID == ObjectIdentifier(windows[1]))
    }

    @Test func keepsAnUntitledTabInPlaceUntilItsTitleArrives() async throws {
        let windows = makeWindows(["First", ""])
        defer { windows.forEach { $0.close() } }
        let model = TerminalTabSidebarModel(window: windows[1])
        let originalOrder = model.tabs.map(\.id)
        #expect(model.tabs.map(\.title) == ["First", ""])

        windows[1].title = "~/project"
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.tabs.map(\.id) == originalOrder)
        #expect(model.tabs.map(\.number) == [1, 2])
        #expect(model.tabs.map(\.title) == ["First", "~/project"])

        windows[1].title = "Terminal"
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.tabs[1].title == "Terminal")
    }

    @Test(.timeLimit(.minutes(1))) func waitsForARealSurfaceTitle() async throws {
        let app = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/cat"
        let controller = TerminalController(app, withBaseConfig: config)
        let window = try #require(makeWindows([""]).first)
        controller.window = window
        defer {
            controller.focusedSurfaceDidChange(to: nil)
            controller.surfaceTree = .init()
            window.close()
        }
        let surface = try #require(controller.surfaceTree.first)
        controller.focusedSurfaceDidChange(to: surface)
        let model = TerminalTabSidebarModel(window: window)

        _ = await surface.$title.values.first(where: { $0 == "👻" })
        await settleWindowChanges()
        #expect(!surface.hasResolvedTitle)
        #expect(model.tabs[0].title.isEmpty)
        #expect(!model.tabs[0].revealState.isRevealed)

        surface.setTitle("~/project")
        _ = await surface.$title.values.first(where: { $0 == "~/project" })
        await settleWindowChanges()
        #expect(surface.hasResolvedTitle)
        #expect(model.tabs[0].title == "~/project")

        surface.setTitle("")
        _ = await surface.$title.values.first(where: \.isEmpty)
        await settleWindowChanges()
        controller.titleOverride = "Named tab"
        await settleWindowChanges()
        #expect(model.tabs[0].title == "Named tab")
    }

    @Test func detachingTheSelectedTabKeepsBothSidebarsAttached() async throws {
        let app = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/cat"
        let controllers = (0..<2).map { _ in TerminalController(app, withBaseConfig: config) }
        defer {
            controllers.forEach {
                $0.focusedSurfaceDidChange(to: nil)
                $0.surfaceTree = .init()
                $0.close()
            }
        }
        let first = try #require(controllers[0].window as? TerminalWindow)
        let second = try #require(controllers[1].window as? TerminalWindow)
        controllers[0].showWindow(nil)
        first.addTabbedWindow(second, ordered: .above)
        controllers[1].showWindow(nil)
        second.makeKeyAndOrderFront(nil)
        await settleWindowChanges()
        let original = TerminalTabSidebarPresentation.shared(for: first)
        #expect(original.view.window === second)

        second.moveTabToNewWindow(nil)
        await settleWindowChanges()
        let detached = TerminalTabSidebarPresentation.shared(for: second)
        #expect(detached !== original)
        #expect(original.view.window === first)
        #expect(detached.view.window === second)
    }

    private func settleWindowChanges() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test(.timeLimit(.minutes(1))) func nativeFullscreenRestoresFrameFromANewTab() async throws {
        let app = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/cat"
        var controllers = [TerminalController(app, withBaseConfig: config)]
        defer {
            controllers.forEach {
                $0.focusedSurfaceDidChange(to: nil)
                $0.surfaceTree = .init()
                $0.close()
            }
        }
        let first = try #require(controllers[0].window as? TerminalWindow)
        controllers[0].showWindow(nil)
        let screen = try #require(first.screen)
        first.setFrame(NSRect(x: screen.visibleFrame.minX + 80, y: screen.visibleFrame.minY + 80,
                              width: 800, height: 500), display: true)
        let windowedFrame = first.frame
        let presentation = TerminalTabSidebarPresentation.shared(for: first)
        var insetChangedDuringTransition = false
        let observation = presentation.model.$topInset.sink { inset in
            if inset == 6 && presentation.model.isTransitioningFullscreen {
                insetChangedDuringTransition = true
            }
        }
        defer { observation.cancel() }

        first.toggleFullScreen(nil)
        try await waitForFullscreen(first, fullscreen: true, presentation: presentation)
        #expect(insetChangedDuringTransition)
        #expect(presentation.windowedFrame == windowedFrame)
        #expect(presentation.model.topInset == 6)

        let fullscreenFrame = first.frame
        let secondController = try #require(TerminalController.newTab(app, from: first, withBaseConfig: config))
        controllers.append(secondController)
        let second = try #require(secondController.window as? TerminalWindow)
        await settleWindowChanges()
        #expect(TerminalTabSidebarPresentation.shared(for: second) === presentation)
        #expect(presentation.windowedFrame == windowedFrame)
        #expect(second.styleMask.contains(.fullScreen))
        #expect(second.frame == fullscreenFrame)
        #expect(presentation.model.topInset == 6)
        second.contentView?.layoutSubtreeIfNeeded()
        let sidebarFrame = presentation.view.convert(presentation.view.bounds, to: nil)
        #expect(abs(sidebarFrame.maxY - second.frame.height) < 1)

        second.toggleFullScreen(nil)
        try await waitForFullscreen(second, fullscreen: false, presentation: presentation)
        #expect(abs(second.frame.minX - windowedFrame.minX) < 1)
        #expect(abs(second.frame.minY - windowedFrame.minY) < 1)
        #expect(abs(second.frame.width - windowedFrame.width) < 1)
        #expect(abs(second.frame.height - windowedFrame.height) < 1)
        #expect(presentation.model.topInset == 26)
    }

    private func waitForFullscreen(_ window: TerminalWindow, fullscreen: Bool,
                                   presentation: TerminalTabSidebarPresentation) async throws {
        for _ in 0..<200 {
            if window.styleMask.contains(.fullScreen) == fullscreen &&
                !presentation.model.isTransitioningFullscreen { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        try #require(window.styleMask.contains(.fullScreen) == fullscreen &&
                     !presentation.model.isTransitioningFullscreen, "Native fullscreen transition did not finish")
    }

    @Test func failedFullscreenTransitionRestoresFrameAndAllowsRetry() throws {
        let windows = makeWindows(["First"])
        defer { windows.forEach { $0.close() } }
        let window = windows[0]
        window.configureTabSidebar()
        let presentation = TerminalTabSidebarPresentation.shared(for: window)
        let originalFrame = window.frame
        let titlebar = try #require(window.titlebarContainer)
        titlebar.alphaValue = 0.75
        presentation.beginFullscreenTransition(for: window, entering: true)
        #expect(titlebar.alphaValue == 0)
        window.setFrame(originalFrame.insetBy(dx: 20, dy: 20), display: false)
        presentation.finishFullscreenTransition(for: window, failed: true)
        #expect(window.frame == originalFrame)
        #expect(!presentation.model.isTransitioningFullscreen)
        #expect(presentation.model.topInset == 26)
        #expect(titlebar.alphaValue == 0.75)

        window.setFrame(originalFrame.offsetBy(dx: 30, dy: 30), display: false)
        presentation.beginFullscreenTransition(for: window, entering: true)
        #expect(presentation.windowedFrame == window.frame)
        presentation.finishFullscreenTransition(for: window, failed: true)
    }

    @Test func sidebarViewportKeepsItsWidthAndBottomWhenTopSpacingChanges() throws {
        let windows = makeWindows(["First"])
        defer { windows.forEach { $0.close() } }
        let presentation = TerminalTabSidebarPresentation.shared(for: windows[0])
        let sidebar = presentation.view
        sidebar.frame = NSRect(x: 0, y: 0, width: 230, height: 500)
        sidebar.layoutSubtreeIfNeeded()
        let viewport = try #require(sidebar.subviews.first)
        #expect(viewport.frame == NSRect(x: 0, y: 26, width: 230, height: 474))

        presentation.model.setTopInset(fullscreen: true)
        #expect(viewport.frame == NSRect(x: 0, y: 6, width: 230, height: 494))
        sidebar.setFrameSize(NSSize(width: 230, height: 800))
        sidebar.layoutSubtreeIfNeeded()
        #expect(viewport.frame == NSRect(x: 0, y: 6, width: 230, height: 794))
        presentation.model.setTopInset(fullscreen: false)
        #expect(viewport.frame == NSRect(x: 0, y: 26, width: 230, height: 774))
    }

    @Test func reordersTabsInBothDirectionsWithoutReplacingContent() {
        let windows = makeWindows(["First", "Second", "Third"])
        defer { windows.forEach { $0.close() } }
        let model = TerminalTabSidebarModel(window: windows[0])
        let originalViews = windows.map(\.contentView)
        let originalOrder = model.tabs.map(\.id)
        let selectedWindow = windows[0].tabGroup?.selectedWindow

        model.move(originalOrder[0], to: originalOrder[2])
        #expect(model.tabs.map(\.id) == [originalOrder[1], originalOrder[2], originalOrder[0]])
        #expect(model.tabs.map(\.number) == [1, 2, 3])
        model.move(originalOrder[0], to: originalOrder[1])
        #expect(model.tabs.map(\.id) == originalOrder)
        #expect(model.tabs.map(\.number) == [1, 2, 3])
        #expect(windows[0].tabGroup?.selectedWindow === selectedWindow)
        for (window, view) in zip(windows, originalViews) {
            #expect(window.contentView === view)
        }
    }

    @Test func tracksNewTabsAfterStartingWithOneWindow() async throws {
        let windows = makeWindows(["First"])
        let others = makeWindows(["New tab"])
        defer { (windows + others).forEach { $0.close() } }
        let model = TerminalTabSidebarModel(window: windows[0])

        others[0].tabbingIdentifier = windows[0].tabbingIdentifier
        windows[0].addTabbedWindow(others[0], ordered: .above)
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.tabs.map(\.title) == ["First", "New tab"])
        #expect(model.tabs.map(\.number) == [1, 2])
    }

    @Test func keepsModelsWithTheirGroupWhenATabMoves() async throws {
        let windows = makeWindows(["First", "Second"])
        let others = makeWindows(["Other"])
        defer { (windows + others).forEach { $0.close() } }
        let model = TerminalTabSidebarModel(window: windows[1])
        let otherModel = TerminalTabSidebarModel(window: others[0])

        windows[1].tabGroup?.removeWindow(windows[1])
        others[0].tabbingIdentifier = windows[1].tabbingIdentifier
        others[0].addTabbedWindow(windows[1], ordered: .above)
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.tabs.map(\.title) == ["First"])
        #expect(otherModel.tabs.map(\.title) == ["Other", "Second"])
    }

    @Test func ignoresReorderFromAnotherGroup() {
        let windows = makeWindows(["First", "Second"])
        let others = makeWindows(["Other"])
        defer { (windows + others).forEach { $0.close() } }
        let model = TerminalTabSidebarModel(window: windows[0])
        let originalOrder = model.tabs.map(\.id)
        model.move(ObjectIdentifier(others[0]), to: originalOrder[0])
        #expect(model.tabs.map(\.id) == originalOrder)
    }

    @Test func newTabReusesTheRenderedSidebarBeforeSelection() {
        let windows = makeWindows(["First"])
        let newWindows = makeWindows([""])
        defer { (windows + newWindows).forEach { $0.close() } }
        let firstSlot = TerminalTabSidebarSlotView(frame: NSRect(x: 0, y: 0, width: 210, height: 400))
        let secondSlot = TerminalTabSidebarSlotView(frame: firstSlot.frame)
        let original = TerminalTabSidebarPresentation.shared(for: windows[0])
        original.present(in: firstSlot)
        let renderedView = original.view
        let firstReveal = original.model.tabs[0].revealState
        firstReveal.reveal()
        var revealUpdates = 0
        let observation = firstReveal.objectWillChange.sink { revealUpdates += 1 }
        defer { observation.cancel() }

        newWindows[0].tabbingIdentifier = windows[0].tabbingIdentifier
        windows[0].addTabbedWindow(newWindows[0], ordered: .above)
        let incoming = TerminalTabSidebarPresentation.shared(for: newWindows[0])
        incoming.present(in: secondSlot)

        #expect(incoming === original)
        #expect(incoming.model === original.model)
        #expect(incoming.view === renderedView)
        #expect(renderedView.superview === secondSlot)
        #expect(incoming.model.tabs.map(\.title) == ["First", ""])
        #expect(incoming.model.tabs[0].revealState === firstReveal)
        #expect(firstReveal.isRevealed)
        #expect(!incoming.model.tabs[1].revealState.isRevealed)

        original.present(in: firstSlot)
        #expect(renderedView.superview === firstSlot)
        #expect(original.model.tabs.map(\.title) == ["First", ""])
        #expect(firstReveal.isRevealed)
        #expect(revealUpdates == 0)
    }

    @Test func detachedTabsGetTheirOwnSidebar() {
        let windows = makeWindows(["First", "Second"])
        defer { windows.forEach { $0.close() } }
        let original = TerminalTabSidebarPresentation.shared(for: windows[0])
        let reveal = original.model.tabs[1].revealState
        reveal.reveal()

        windows[1].tabGroup?.removeWindow(windows[1])
        let detached = TerminalTabSidebarPresentation.shared(for: windows[1])
        #expect(detached !== original)
        #expect(detached.model !== original.model)
        #expect(TerminalTabSidebarPresentation.shared(for: windows[0]) === original)
        #expect(detached.model.tabs[0].revealState === reveal)
        #expect(reveal.isRevealed)
    }

    @Test func unrelatedWindowChangesDoNotRedrawSidebar() async throws {
        let windows = makeWindows(["First"])
        let others = makeWindows(["Other"])
        defer { (windows + others).forEach { $0.close() } }
        let model = TerminalTabSidebarModel(window: windows[0])
        var updates = 0
        let observation = model.objectWillChange.sink { updates += 1 }
        defer { observation.cancel() }

        others[0].title = "Unrelated title update"
        NotificationCenter.default.post(name: TerminalTabSidebarModel.didChange, object: others[0])
        try await Task.sleep(for: .milliseconds(50))
        #expect(updates == 0)
    }

    @Test func terminalHasConsistentInsetsWithNativeTabs() async throws {
        let identifier = UUID().uuidString
        let terminals = [NSView(), NSView()]
        let windows = terminals.map { terminal in
            let window = TerminalWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false
            )
            window.isReleasedWhenClosed = false
            window.tabbingIdentifier = identifier
            window.configureTabSidebar()
            window.contentView = TerminalViewContainer {
                TerminalSidebarContainer(sidebar: TerminalTabSidebarSlotView()) {
                    LayoutProbe(view: terminal)
                }
            }
            window.setContentSize(NSSize(width: 640, height: 400))
            return window
        }
        defer { windows.forEach { $0.close() } }

        windows[0].addTabbedWindow(windows[1], ordered: .above)
        for (window, terminal) in zip(windows, terminals) {
            window.tabGroup?.selectedWindow = window
            window.title = "Updated title"
            window.contentView?.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
            let terminalFrame = terminal.convert(terminal.bounds, to: nil)
            #expect(abs(window.frame.height - terminalFrame.maxY - 12) < 1)
            #expect(abs(terminalFrame.minY - 12) < 1)
            #expect(abs(window.frame.width - terminalFrame.maxX - 12) < 1)
            #expect(abs(terminalFrame.minX - TerminalTabSidebarLayout.initialWidth - 13) < 1)
            #expect(window.titleVisibility == .hidden)
            #expect(window.standardWindowButton(.closeButton)?.isHidden == false)
        }
    }
}

private struct LayoutProbe: NSViewRepresentable {
    let view: NSView
    func makeNSView(context: Context) -> NSView { view }
    func updateNSView(_ view: NSView, context: Context) {}
}
