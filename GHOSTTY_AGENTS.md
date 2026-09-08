# Ghostty Agents

A personal macOS fork of Ghostty for agentic coding.

## Tab sidebar

Tabs appear in a resizable left column, enabled by default.
The sidebar supports numbered tabs, live titles, tab colors, bell indicators,
and drag reordering from anywhere on a tab row. Neighboring tabs slide aside as
you drag; Escape cancels the move. A right-click menu supports renaming or closing tabs. Existing shortcuts,
splits, close confirmations, undo, and session restoration use Ghostty's native
tab groups. Sidebar width is remembered across windows and launches.
Each tab group owns one sidebar view and model, preserving its rows and scroll state
when a new tab opens or the selected tab changes.
Tab numbers and titles fade in together once the title is available. Each terminal
window retains its reveal state so switching or moving tabs cannot replay the fade.
The selected tab's number is larger, bold, and brighter.

The terminal and sidebar fill the window height, with native window buttons
over the sidebar and no title strip. Drag the sidebar header to move the window.
The sidebar overrides `macos-titlebar-style`.
To restore the upstream tab layout, add `macos-tab-sidebar = false` to your
Ghostty configuration and restart the app. Quick Terminal retains its existing UI.

## Build

Requires Xcode 26 with the Metal Toolchain, Zig 0.16.0, and Nushell.

```sh
brew install nushell swiftlint
xcodebuild -downloadComponent MetalToolchain
bash macos/setup-local-signing.sh
./build-agents.sh
```

Signing setup is needed once per Mac. It creates the `Ghostty Sidebar Local`
identity in the login Keychain, trusted for code signing only. Keep that identity
across rebuilds so macOS permissions persist. On the first signing operation,
enter your password only in macOS's native dialog and click **Always Allow**;
**Allow** grants access for one operation.

Set `ZIG=/path/to/zig` if Zig is not on your PATH. The optimized, locally signed
app is written to `macos/build/ReleaseLocal/Ghostty Agents.app`. Its display name is
**Ghostty Agents**, with a separate bundle identifier (`uy.joaqo.ghostty.sidebar`)
so it can coexist with the official app. It reads Ghostty's usual config files.
The bundle identifier and signing certificate keep their original names so
existing permissions and preferences remain valid.
The fork's updater is disabled; rebuild this checkout to update it.

On this machine, the downloaded Zig toolchain can be used with:

```sh
ZIG="$HOME/.local/share/ghostty-build/zig-aarch64-macos-0.16.0/zig" ./build-agents.sh
```

Quit Ghostty Agents before replacing the installed app. Launch with a clean
environment so agent settings such as `NO_COLOR` cannot disable terminal colors.

```sh
ditto "macos/build/ReleaseLocal/Ghostty Agents.app" "/Applications/Ghostty Agents.app"
env -i HOME="$HOME" USER="$USER" LOGNAME="$LOGNAME" \
  PATH="/usr/bin:/bin:/usr/sbin:/sbin" \
  /usr/bin/open "/Applications/Ghostty Agents.app"
```

When switching from an ad-hoc build, an enabled Accessibility entry can still
refer to an old build's hash. Quit Ghostty Agents, remove its entry from
System Settings → Privacy & Security → Accessibility, then add
`/Applications/Ghostty Agents.app` and enable it again. This replaces the stale
permission with one tied to the persistent signing identity.

## Checks

```sh
macos/build.nu --action test
```

The sidebar tests exercise real AppKit tab groups, including live title and
selection changes, closing tabs, reordering, and moving between window groups.
