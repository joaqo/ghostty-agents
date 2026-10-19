import AppKit
import GhosttyKit
import Testing
@testable import Ghostty

@Suite(.serialized)
@MainActor
struct TerminalBackgroundTabTests {
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        try #require(condition())
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true], [false, true])
    func backgroundTabKeepsTheSelectedTab(minimized: Bool, sidebarHidden: Bool) async throws {
        let app = try #require((NSApp.delegate as? AppDelegate)?.ghostty)
        var config = Ghostty.SurfaceConfiguration()
        config.command = "/bin/cat"
        let firstController = TerminalController(app, withBaseConfig: config)
        var controllers = [firstController]
        defer {
            controllers.forEach {
                $0.focusedSurfaceDidChange(to: nil)
                $0.surfaceTree = .init()
                $0.close()
            }
        }
        let first = try #require(firstController.window as? TerminalWindow)
        firstController.showWindow(nil)
        let selectedController = try #require(TerminalController.newTab(app, from: first, withBaseConfig: config))
        controllers.append(selectedController)
        let selected = try #require(selectedController.window as? TerminalWindow)
        try await waitUntil { first.tabGroup?.selectedWindow === selected }
        let group = try #require(first.tabGroup)
        let presentation = TerminalTabSidebarPresentation.shared(for: selected)
        if sidebarHidden {
            presentation.model.toggleVisibility()
        }
        if minimized {
            selected.miniaturize(nil)
            try await waitUntil { selected.isMiniaturized }
        }

        let background = try #require(TerminalController.newTab(
            app, from: first, withBaseConfig: config, focus: false
        ))
        controllers.append(background)
        let backgroundWindow = try #require(background.window as? TerminalWindow)
        try await Task.sleep(for: .milliseconds(300))

        #expect(group.windows.last === backgroundWindow)
        #expect(group.selectedWindow === selected)
        #expect(!backgroundWindow.isVisible)
        #expect(!backgroundWindow.isKeyWindow)
        #expect(selected.isMiniaturized == minimized)
        if !minimized {
            #expect(presentation.view.window === selected)
        }

        let selectedSurface = try #require(selectedController.surfaceTree.first)
        let backgroundSurface = try #require(background.surfaceTree.first)
        try await waitUntil {
            guard let selectedSize = selectedSurface.surfaceSize,
                  let backgroundSize = backgroundSurface.surfaceSize else { return false }
            return (backgroundSize.columns, backgroundSize.rows) == (selectedSize.columns, selectedSize.rows)
        }

        if minimized {
            selected.deminiaturize(nil)
            try await waitUntil { !selected.isMiniaturized && selected.isVisible }
            #expect(group.selectedWindow === selected)
            #expect(group.windows.last === backgroundWindow)
        }

        backgroundWindow.makeKeyAndOrderFront(nil)
        try await waitUntil { group.selectedWindow === backgroundWindow }
        try await waitUntil { backgroundWindow.backgroundColor == selected.backgroundColor }
    }
}
