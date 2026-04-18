import Foundation
import AppKit
import Carbon.HIToolbox

// Forward-declared protocol for callback userdata. `GhosttyTerminalView` (NSView)
// conforms to this so libghostty's C callbacks can walk back to the owning view
// without kanbario having to know about libghostty's internal surface layout.
protocol GhosttySurfaceOwning: AnyObject {
    var surfaceId: UUID { get }
    var runtimeSurface: ghostty_surface_t? { get }
    func ghosttyDidRequestClose(needsConfirm: Bool)
}

final class GhosttySurfaceCallbackContext {
    weak var owner: GhosttySurfaceOwning?
    let surfaceId: UUID

    init(owner: GhosttySurfaceOwning) {
        self.owner = owner
        self.surfaceId = owner.surfaceId
    }

    var runtimeSurface: ghostty_surface_t? {
        owner?.runtimeSurface
    }
}

// `flagsChanged` is used for both modifier presses and releases on macOS.
// Returning the wrong edge leaves Ghostty with a phantom held modifier until
// a later focus loss flushes release events into the PTY.
// Lifted verbatim from cmux `Sources/GhosttyTerminalView.swift` §56-102.
func kanbarioGhosttyModifierActionForFlagsChanged(
    keyCode: UInt16,
    modifierFlagsRawValue: UInt
) -> ghostty_input_action_e? {
    let flags = NSEvent.ModifierFlags(rawValue: modifierFlagsRawValue)
    let modifierActive: Bool
    switch keyCode {
    case 0x39:
        modifierActive = flags.contains(.capsLock)
    case 0x38, 0x3C:
        modifierActive = flags.contains(.shift)
    case 0x3B, 0x3E:
        modifierActive = flags.contains(.control)
    case 0x3A, 0x3D:
        modifierActive = flags.contains(.option)
    case 0x37, 0x36:
        modifierActive = flags.contains(.command)
    default:
        return nil
    }

    guard modifierActive else { return GHOSTTY_ACTION_RELEASE }

    let sidePressed: Bool
    switch keyCode {
    case 0x38:
        sidePressed = modifierFlagsRawValue & UInt(NX_DEVICELSHIFTKEYMASK) != 0
    case 0x3C:
        sidePressed = modifierFlagsRawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0
    case 0x3B:
        sidePressed = modifierFlagsRawValue & UInt(NX_DEVICELCTLKEYMASK) != 0
    case 0x3E:
        sidePressed = modifierFlagsRawValue & UInt(NX_DEVICERCTLKEYMASK) != 0
    case 0x3A:
        sidePressed = modifierFlagsRawValue & UInt(NX_DEVICELALTKEYMASK) != 0
    case 0x3D:
        sidePressed = modifierFlagsRawValue & UInt(NX_DEVICERALTKEYMASK) != 0
    case 0x37:
        sidePressed = modifierFlagsRawValue & UInt(NX_DEVICELCMDKEYMASK) != 0
    case 0x36:
        sidePressed = modifierFlagsRawValue & UInt(NX_DEVICERCMDKEYMASK) != 0
    default:
        sidePressed = true
    }

    return sidePressed ? GHOSTTY_ACTION_PRESS : GHOSTTY_ACTION_RELEASE
}

// Shim so the `read_clipboard_cb` pointer type is C-ABI compatible.
// Some GhosttyKit builds import this callback as returning `Void` in Swift
// even though the C ABI returns `bool`; unsafeBitCast of a `@convention(c)`
// function sidesteps the mismatch (same trick cmux uses).
private func kanbarioRuntimeReadClipboardCallback(
    _ userdata: UnsafeMutableRawPointer?,
    _ location: ghostty_clipboard_e,
    _ state: UnsafeMutableRawPointer?
) -> Bool {
    GhosttyApp.runtimeReadClipboardCallback(userdata, location, state)
}

final class GhosttyApp {
    static let shared = GhosttyApp()

    private(set) var app: ghostty_app_t?
    private(set) var config: ghostty_config_t?

    // Coalesce wakeup → tick dispatches. The I/O thread fires wakeup_cb
    // thousands of times per second during bulk output; we keep at most one
    // pending tick on the main queue at any time.
    private var _tickScheduled = false
    private let _tickLock = NSLock()

    private var appObservers: [NSObjectProtocol] = []

    private init() {
        initializeGhostty()
    }

    private func initializeGhostty() {
        // TUI apps rely on color even when the launcher set NO_COLOR.
        if getenv("NO_COLOR") != nil {
            unsetenv("NO_COLOR")
        }

        let result = ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv)
        if result != GHOSTTY_SUCCESS {
            NSLog("kanbario: ghostty_init failed: \(result)")
            return
        }

        guard let config = ghostty_config_new() else {
            NSLog("kanbario: ghostty_config_new failed")
            return
        }

        // macos-background-from-layer: let libghostty paint through the NSView's
        //   CAMetalLayer background, which is what we want for embedded panes.
        // shell-integration = none: Claude Code drives its own prompt, so we
        //   don't want Ghostty injecting rcfile hooks into the child shell.
        loadInlineConfig(
            "macos-background-from-layer = true\nshell-integration = none",
            into: config
        )
        ghostty_config_finalize(config)

        var runtimeConfig = ghostty_runtime_config_s()
        runtimeConfig.userdata = Unmanaged.passUnretained(self).toOpaque()
        runtimeConfig.supports_selection_clipboard = true
        runtimeConfig.wakeup_cb = { _ in
            GhosttyApp.shared.scheduleTick()
        }
        runtimeConfig.action_cb = { _, target, action in
            return GhosttyApp.shared.handleAction(target: target, action: action)
        }
        runtimeConfig.read_clipboard_cb = unsafeBitCast(
            kanbarioRuntimeReadClipboardCallback as @convention(c) (
                UnsafeMutableRawPointer?,
                ghostty_clipboard_e,
                UnsafeMutableRawPointer?
            ) -> Bool,
            to: ghostty_runtime_read_clipboard_cb.self
        )
        runtimeConfig.confirm_read_clipboard_cb = { userdata, content, state, _ in
            guard let content else { return }
            guard let ctx = GhosttyApp.callbackContext(from: userdata),
                  let surface = ctx.runtimeSurface else { return }
            ghostty_surface_complete_clipboard_request(surface, content, state, true)
        }
        runtimeConfig.write_clipboard_cb = { _, location, content, len, _ in
            guard let content = content, len > 0 else { return }
            let buffer = UnsafeBufferPointer(start: content, count: Int(len))
            for item in buffer {
                guard let dataPtr = item.data else { continue }
                let value = String(cString: dataPtr)
                if let mimePtr = item.mime {
                    let mime = String(cString: mimePtr)
                    if mime.hasPrefix("text/plain") {
                        GhosttyClipboard.writeString(value, to: location)
                        return
                    }
                }
                GhosttyClipboard.writeString(value, to: location)
                return
            }
        }
        runtimeConfig.close_surface_cb = { userdata, needsConfirmClose in
            guard let ctx = GhosttyApp.callbackContext(from: userdata) else { return }
            DispatchQueue.main.async {
                ctx.owner?.ghosttyDidRequestClose(needsConfirm: needsConfirmClose)
            }
        }

        guard let created = ghostty_app_new(&runtimeConfig, config) else {
            NSLog("kanbario: ghostty_app_new failed")
            ghostty_config_free(config)
            return
        }

        self.app = created
        self.config = config

        ghostty_app_set_focus(created, NSApp.isActive)

        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, true)
        })
        appObservers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let app = self?.app else { return }
            ghostty_app_set_focus(app, false)
        })
    }

    func scheduleTick() {
        _tickLock.lock()
        defer { _tickLock.unlock() }
        guard !_tickScheduled else { return }
        _tickScheduled = true
        DispatchQueue.main.async {
            self.tick()
        }
    }

    private func tick() {
        _tickLock.lock()
        _tickScheduled = false
        _tickLock.unlock()

        guard let app = app else { return }
        ghostty_app_tick(app)
    }

    fileprivate static func callbackContext(from userdata: UnsafeMutableRawPointer?) -> GhosttySurfaceCallbackContext? {
        guard let userdata else { return nil }
        return Unmanaged<GhosttySurfaceCallbackContext>.fromOpaque(userdata).takeUnretainedValue()
    }

    fileprivate static func runtimeReadClipboardCallback(
        _ userdata: UnsafeMutableRawPointer?,
        _ location: ghostty_clipboard_e,
        _ state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let ctx = callbackContext(from: userdata),
              let requestSurface = ctx.runtimeSurface else { return false }

        DispatchQueue.main.async {
            let text = GhosttyClipboard.readString(from: location) ?? ""
            guard ctx.runtimeSurface == requestSurface else { return }
            text.withCString { ptr in
                ghostty_surface_complete_clipboard_request(requestSurface, ptr, state, false)
            }
        }

        return true
    }

    // Minimal action stub. kanbario drives surface lifecycle from the kanban
    // board (Start button / drag-to-done), so we decline Ghostty's tab / split /
    // fullscreen / config-reload actions by returning false. Surface-scoped
    // redraw / cursor / scroll actions that libghostty handles internally are
    // unaffected because they don't go through this callback.
    private func handleAction(target: ghostty_target_s, action: ghostty_action_s) -> Bool {
        _ = target
        _ = action
        return false
    }

    private func loadInlineConfig(_ contents: String, into config: ghostty_config_t) {
        let trimmed = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("kanbario-inline-\(UUID().uuidString).conf")
        do {
            try trimmed.write(to: tmpURL, atomically: true, encoding: .utf8)
            defer { try? FileManager.default.removeItem(at: tmpURL) }
            tmpURL.path.withCString { path in
                ghostty_config_load_file(config, path)
            }
        } catch {
            NSLog("kanbario: inline config load failed: \(error.localizedDescription)")
        }
    }
}

// Thin NSPasteboard wrapper for Ghostty's clipboard callbacks. Mirrors cmux's
// text-only path in `GhosttyPasteboardHelper` — image / file-URL plumbing is
// intentionally omitted for MVP.
enum GhosttyClipboard {
    private static let selectionPasteboard = NSPasteboard(
        name: NSPasteboard.Name("com.mitchellh.ghostty.selection")
    )

    static func pasteboard(for location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD: return .general
        case GHOSTTY_CLIPBOARD_SELECTION: return selectionPasteboard
        default: return nil
        }
    }

    static func readString(from location: ghostty_clipboard_e) -> String? {
        guard let pasteboard = pasteboard(for: location) else { return nil }
        return pasteboard.string(forType: .string)
    }

    static func writeString(_ value: String, to location: ghostty_clipboard_e) {
        guard let pasteboard = pasteboard(for: location) else { return }
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
    }
}
