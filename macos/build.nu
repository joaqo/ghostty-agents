#!/usr/bin/env nu

# Build the macOS Ghostty app using xcodebuild with a clean environment
# to avoid Nix shell interference (NIX_LDFLAGS, NIX_CFLAGS_COMPILE, etc.).

def main [
    --scheme: string = "Ghostty"       # Xcode scheme (Ghostty, Ghostty-iOS, DockTilePlugin)
    --configuration: string = "Debug"  # Build configuration (Debug, Release, ReleaseLocal)
    --action: string = "build"         # xcodebuild action (build, test, clean, etc.)
    --arch: string                    # Build only this architecture (arm64, x86_64)
    --test-filter: string             # Run only the named test target, suite, or test
] {
    let project = ($env.FILE_PWD | path join "Ghostty.xcodeproj")
    let build_dir = ($env.FILE_PWD | path join "build")
    let architecture = if $arch == null { [] } else { [$"ARCHS=($arch)"] }
    let test_filter = if $test_filter == null { [] } else { [-only-testing $test_filter] }

    # Skip UI tests for CLI-based invocations because it requires
    # special permissions.
    let skip_testing = if $action == "test" {
        # AppKit tests share desktop Spaces, so their app hosts must run serially.
        [-skip-testing GhosttyUITests -parallel-testing-enabled NO "ENABLE_TESTABILITY=YES"]
    } else {
        []
    }

    (^env -i
        $"HOME=($env.HOME)"
        "PATH=/usr/bin:/bin:/usr/sbin:/sbin"
        xcodebuild
        -project $project
        -scheme $scheme
        -configuration $configuration
        $"SYMROOT=($build_dir)"
        ...$architecture
        ...$skip_testing
        ...$test_filter
        $action)
}
