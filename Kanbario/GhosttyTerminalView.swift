import Foundation
import AppKit
import SwiftUI
import QuartzCore
import Metal
import Carbon.HIToolbox

// MARK: - NSScreen helper (copied from cmux §8677)

private extension NSScreen {
    var displayID: UInt32? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let v = deviceDescription[key] as? UInt32 { return v }
        if let v = deviceDescription[key] as? Int { return UInt32(v) }
        if let v = deviceDescription[key] as? NSNumber { return v.uint32Value }
        return nil
    }
}

// MARK: - Terminal Surface (owns the ghostty_surface_t lifecycle)

/// Wraps a single `ghostty_surface_t`. kanbario creates one surface per task —
/// the kanban board's Start button instantiates `TerminalSurface`, attaches the
/// NSView, libghostty fork+execves `claude` (or any configured command), and
/// stdout goes straight to the GPU renderer via CAMetalLayer.
final class TerminalSurface {
    let id: UUID
    fileprivate(set) var surface: ghostty_surface_t?

    /// Command spec: libghostty owns the PTY (unlike the pre-Milestone-D path
    /// where `SessionManager` spawned via openpty + Foundation.Process).
    /// `ghostty_surface_new` forks and execs this command itself.
    private let command: String?
    private let workingDirectory: String?
    private let initialInput: String?
    private let environment: [String: String]

    private weak var attachedView: GhosttyNSView?
    private var surfaceCallbackContext: Unmanaged<GhosttySurfaceCallbackContext>?

    // Last-applied pixel dimensions so we skip redundant set_size calls.
    private var lastPixelWidth: UInt32 = 0
    private var lastPixelHeight: UInt32 = 0
    private var lastXScale: CGFloat = 0
    private var lastYScale: CGFloat = 0

    init(
        id: UUID = UUID(),
        command: String? = nil,
        workingDirectory: String? = nil,
        initialInput: String? = nil,
        environment: [String: String] = [:]
    ) {
        self.id = id
        self.command = command
        self.workingDirectory = workingDirectory
        self.initialInput = initialInput
        self.environment = environment
    }

    deinit {
        // Final safety net — teardownSurface should have already run in the
        // owning view's lifecycle.
        if let surface {
            ghostty_surface_free(surface)
        }
        surfaceCallbackContext?.release()
    }

    var isLive: Bool { surface != nil }

    func attachToView(_ view: GhosttyNSView) {
        attachedView = view
        if surface == nil {
            createSurface(for: view)
        }
    }

    @MainActor
    func teardown() {
        let callbackContext = surfaceCallbackContext
        surfaceCallbackContext = nil

        let surfaceToFree = surface
        surface = nil

        guard let surfaceToFree else {
            callbackContext?.release()
            return
        }

        // Match cmux: defer the free to the next main-actor turn so SIGHUP
        // delivery is deterministic but non-reentrant.
        Task { @MainActor in
            ghostty_surface_free(surfaceToFree)
            callbackContext?.release()
        }
    }

    /// Match upstream Ghostty AppKit sizing: framebuffer dimensions are derived
    /// from backing-space points and truncated (never rounded up). (cmux §4140)
    private func pixelDimension(from value: CGFloat) -> UInt32 {
        guard value.isFinite else { return 0 }
        let floored = floor(max(0, value))
        if floored >= CGFloat(UInt32.max) { return UInt32.max }
        return UInt32(floored)
    }

    private func scaleFactors(for view: GhosttyNSView) -> (x: CGFloat, y: CGFloat, layer: CGFloat) {
        let scale = max(
            1.0,
            view.window?.backingScaleFactor
                ?? view.layer?.contentsScale
                ?? NSScreen.main?.backingScaleFactor
                ?? 1.0
        )
        return (scale, scale, scale)
    }

    private func scaleApproximatelyEqual(_ lhs: CGFloat, _ rhs: CGFloat, epsilon: CGFloat = 0.0001) -> Bool {
        abs(lhs - rhs) <= epsilon
    }

    private func createSurface(for view: GhosttyNSView) {
        guard let app = GhosttyApp.shared.app else {
            NSLog("kanbario: ghostty app not initialized; cannot create surface")
            return
        }

        let scaleFactors = scaleFactors(for: view)

        var surfaceConfig = ghostty_surface_config_new()
        surfaceConfig.platform_tag = GHOSTTY_PLATFORM_MACOS
        surfaceConfig.platform = ghostty_platform_u(macos: ghostty_platform_macos_s(
            nsview: Unmanaged.passUnretained(view).toOpaque()
        ))

        // userdata is a retained GhosttySurfaceCallbackContext. Retain balance:
        // passRetained here, released in teardown() / deinit.
        let callbackContext = Unmanaged.passRetained(GhosttySurfaceCallbackContext(owner: view))
        surfaceConfig.userdata = callbackContext.toOpaque()
        surfaceCallbackContext?.release()
        surfaceCallbackContext = callbackContext

        surfaceConfig.scale_factor = scaleFactors.layer

        // Build the env_var array. libghostty copies the strings, so the owning
        // storage only needs to outlive the ghostty_surface_new call.
        var envVars: [ghostty_env_var_s] = []
        var envStorage: [(UnsafeMutablePointer<CChar>, UnsafeMutablePointer<CChar>)] = []
        defer {
            for (key, value) in envStorage {
                free(key)
                free(value)
            }
        }
        for (key, value) in environment {
            guard let keyPtr = strdup(key), let valuePtr = strdup(value) else { continue }
            envStorage.append((keyPtr, valuePtr))
            envVars.append(ghostty_env_var_s(key: keyPtr, value: valuePtr))
        }

        func withOptionalCString<T>(_ value: String?, _ body: (UnsafePointer<CChar>?) -> T) -> T {
            guard let value else { return body(nil) }
            return value.withCString(body)
        }

        withOptionalCString(command) { cCommand in
            surfaceConfig.command = cCommand
            withOptionalCString(workingDirectory) { cWorkingDir in
                surfaceConfig.working_directory = cWorkingDir
                withOptionalCString(initialInput) { cInitialInput in
                    surfaceConfig.initial_input = cInitialInput
                    if envVars.isEmpty {
                        self.surface = ghostty_surface_new(app, &surfaceConfig)
                    } else {
                        envVars.withUnsafeMutableBufferPointer { buffer in
                            surfaceConfig.env_vars = buffer.baseAddress
                            surfaceConfig.env_var_count = buffer.count
                            self.surface = ghostty_surface_new(app, &surfaceConfig)
                        }
                    }
                }
            }
        }

        guard let createdSurface = surface else {
            surfaceCallbackContext?.release()
            surfaceCallbackContext = nil
            NSLog("kanbario: ghostty_surface_new returned nil")
            return
        }

        // vsync-driven rendering needs the display ID up front; otherwise the
        // renderer can think vsync is running but never deliver frames
        // (cmux §4525-4536).
        if let screen = view.window?.screen ?? NSScreen.main,
           let displayID = screen.displayID,
           displayID != 0 {
            ghostty_surface_set_display_id(createdSurface, displayID)
        }

        ghostty_surface_set_content_scale(createdSurface, scaleFactors.x, scaleFactors.y)
        let backingSize = view.convertToBacking(NSRect(origin: .zero, size: view.bounds.size)).size
        let wpx = pixelDimension(from: backingSize.width)
        let hpx = pixelDimension(from: backingSize.height)
        if wpx > 0, hpx > 0 {
            ghostty_surface_set_size(createdSurface, wpx, hpx)
            lastPixelWidth = wpx
            lastPixelHeight = hpx
            lastXScale = scaleFactors.x
            lastYScale = scaleFactors.y
        }

        ghostty_surface_refresh(createdSurface)
    }

    @discardableResult
    func updateSize(
        width: CGFloat,
        height: CGFloat,
        xScale: CGFloat,
        yScale: CGFloat,
        backingSize: CGSize? = nil
    ) -> Bool {
        guard let surface else { return false }

        let resolvedBackingWidth = backingSize?.width ?? (width * xScale)
        let resolvedBackingHeight = backingSize?.height ?? (height * yScale)
        let wpx = pixelDimension(from: resolvedBackingWidth)
        let hpx = pixelDimension(from: resolvedBackingHeight)
        guard wpx > 0, hpx > 0 else { return false }

        let scaleChanged = !scaleApproximatelyEqual(xScale, lastXScale) || !scaleApproximatelyEqual(yScale, lastYScale)
        let sizeChanged = wpx != lastPixelWidth || hpx != lastPixelHeight
        guard scaleChanged || sizeChanged else { return false }

        if scaleChanged {
            ghostty_surface_set_content_scale(surface, xScale, yScale)
            lastXScale = xScale
            lastYScale = yScale
        }
        if sizeChanged {
            ghostty_surface_set_size(surface, wpx, hpx)
            lastPixelWidth = wpx
            lastPixelHeight = hpx
        }
        return true
    }

    func setFocus(_ focused: Bool) {
        guard let surface else { return }
        ghostty_surface_set_focus(surface, focused)
    }

    func refresh() {
        guard let surface else { return }
        ghostty_surface_refresh(surface)
    }

    /// Gracefully request the child to close. libghostty delivers SIGHUP to the
    /// PTY, which the shell / claude forwards along. The close_surface_cb fires
    /// once the child has wound down; callers should treat this as a hint rather
    /// than a synchronous termination.
    func requestClose() {
        guard let surface else { return }
        ghostty_surface_request_close(surface)
    }
}

// MARK: - NSView subclass

/// `NSView` that hosts a ghostty surface. kanbario's first cut keeps this file
/// focused on rendering + surface lifecycle; keyboard (D-c.2b) and IME (D-c.2c)
/// land in follow-up commits to keep diffs reviewable.
final class GhosttyNSView: NSView, GhosttySurfaceOwning {
    let surfaceId: UUID
    private(set) var terminalSurface: TerminalSurface?

    var runtimeSurface: ghostty_surface_t? { terminalSurface?.surface }

    /// Called by `GhosttyApp`'s `close_surface_cb`. kanbario's kanban board
    /// typically cleans up via the drag-to-done / task-end path; we wire this
    /// to the same teardown so hook-driven closes work too. Actual task-state
    /// plumbing lives in `SessionManager` (see D-c step 3).
    var onCloseRequested: ((_ needsConfirm: Bool) -> Void)?

    // MARK: - IME state (D-c.2c)
    //
    // AppKit's text input system (NSTextInputClient) drives IME by asking us to
    // hold marked text during composition and swap it for committed text on
    // confirmation. Everything below mirrors cmux's layout — see the
    // NSTextInputClient extension at the bottom of this file.

    /// Current IME preedit (composition) text. Empty when nothing is being
    /// composed. `hasMarkedText()` checks this length.
    fileprivate var markedText = NSMutableAttributedString()

    /// Populated by `insertText` during a `keyDown` → `interpretKeyEvents`
    /// cycle, consumed at the end of `keyDown`. When nil we're outside a
    /// keyDown event (e.g. AX / dictation) and should send text directly.
    fileprivate var keyTextAccumulator: [String]?

    /// Glyph cell size reported by libghostty, used for IME candidate window
    /// positioning. cmux pipes this from a Ghostty action_cb notification —
    /// kanbario's MVP stub leaves it at .zero (firstRect uses a sensible
    /// fallback) and revisits once we wire action_cb notifications.
    fileprivate var cellSize: CGSize = .zero

    init(terminalSurface: TerminalSurface) {
        self.surfaceId = terminalSurface.id
        self.terminalSurface = terminalSurface
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) {
        fatalError("GhosttyNSView does not support NSCoder")
    }

    deinit {
        // Surface may already be torn down via explicit teardown(); if not,
        // the TerminalSurface deinit safety net will fire.
        terminalSurface = nil
    }

    override func makeBackingLayer() -> CALayer {
        // cmux §5400. bgra8Unorm + isOpaque=false + framebufferOnly=false is
        // the combination Ghostty's macOS renderer expects; framebufferOnly=false
        // in particular is required for background-opacity/blur.
        let metalLayer = CAMetalLayer()
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = false
        return metalLayer
    }

    private func setup() {
        wantsLayer = true
        layer?.masksToBounds = true
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok, let surface = runtimeSurface {
            ghostty_surface_set_focus(surface, true)
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        if let surface = runtimeSurface {
            ghostty_surface_set_focus(surface, false)
        }
        return super.resignFirstResponder()
    }

    // MARK: - Key input (D-c.2b + 2c IME integration)

    override func keyDown(with event: NSEvent) {
        guard let surface = runtimeSurface else {
            super.keyDown(with: event)
            return
        }

        // Ctrl-modified terminal input (for example Ctrl+D): send a deterministic
        // Ghostty key event without AppKit text interpretation. cmux §6699-6762.
        // This bypass is only safe when no IME composition is active, since
        // interpretKeyEvents is the only way to let the IME react.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.control),
           !flags.contains(.command),
           !flags.contains(.option),
           !hasMarkedText() {
            ghostty_surface_set_focus(surface, true)
            if sendBasicKey(surface: surface, event: event, useIgnoringModifiers: true) {
                return
            }
        }

        // IME / text-composition path (cmux §6764-7100 condensed). The trick is:
        //   1. Set keyTextAccumulator so insertText can append into it.
        //   2. Let AppKit's interpretKeyEvents deliver the key to the active
        //      input method. IME composition calls setMarkedText (no text);
        //      confirmation calls insertText (fills accumulator).
        //   3. Sync preedit back to libghostty so Ghostty can render the
        //      composition overlay on top of the cell grid.
        //   4. If accumulated text is present, send it as a single key event
        //      with the text payload. If we're still mid-composition (marked
        //      text non-empty), don't send a raw key event.

        let markedTextBefore = markedText.length > 0

        keyTextAccumulator = []
        defer { keyTextAccumulator = nil }

        interpretKeyEvents([event])

        syncPreedit(clearIfNeeded: markedTextBefore)

        let accumulated = (keyTextAccumulator ?? []).joined()
        if !accumulated.isEmpty {
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
            keyEvent.keycode = UInt32(event.keyCode)
            keyEvent.mods = modsFromEvent(event)
            keyEvent.consumed_mods = consumedModsFromFlags(event.modifierFlags)
            keyEvent.composing = false
            keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)
            accumulated.withCString { ptr in
                keyEvent.text = ptr
                _ = ghostty_surface_key(surface, keyEvent)
            }
            return
        }

        // No text produced and no composition ongoing → send a bare key event
        // so Ghostty can encode function / arrow keys via its KeyEncoder.
        if !markedTextBefore && !hasMarkedText() {
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
            keyEvent.keycode = UInt32(event.keyCode)
            keyEvent.mods = modsFromEvent(event)
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.composing = false
            keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)
            keyEvent.text = nil
            _ = ghostty_surface_key(surface, keyEvent)
        }
        // If we're mid-composition (markedText non-empty after interpretKeyEvents)
        // swallow the raw event — Ghostty gets the preedit overlay via syncPreedit
        // and the committed text will arrive on the next insertText call.
    }

    override func flagsChanged(with event: NSEvent) {
        guard let surface = runtimeSurface else {
            super.flagsChanged(with: event)
            return
        }

        if !hasMarkedText(),
           let action = kanbarioGhosttyModifierActionForFlagsChanged(
            keyCode: event.keyCode,
            modifierFlagsRawValue: event.modifierFlags.rawValue
           ) {
            // Modifier-only events carry no text; avoid unshiftedCodepointFromEvent
            // which probes AppKit character APIs that aren't safe for modifier-only
            // events. cmux §7105-7130.
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = action
            keyEvent.keycode = UInt32(event.keyCode)
            keyEvent.mods = modsFromEvent(event)
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.text = nil
            keyEvent.composing = false
            keyEvent.unshifted_codepoint = 0
            _ = ghostty_surface_key(surface, keyEvent)
        }
    }

    @discardableResult
    private func sendBasicKey(
        surface: ghostty_surface_t,
        event: NSEvent,
        useIgnoringModifiers: Bool
    ) -> Bool {
        var keyEvent = ghostty_input_key_s()
        keyEvent.action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS
        keyEvent.keycode = UInt32(event.keyCode)
        keyEvent.mods = modsFromEvent(event)
        keyEvent.consumed_mods = GHOSTTY_MODS_NONE
        keyEvent.composing = false
        keyEvent.unshifted_codepoint = unshiftedCodepointFromEvent(event)

        let text: String
        if useIgnoringModifiers {
            text = event.charactersIgnoringModifiers ?? event.characters ?? ""
        } else {
            text = textForKeyEvent(event) ?? ""
        }

        if text.isEmpty {
            keyEvent.text = nil
            return ghostty_surface_key(surface, keyEvent)
        }
        return text.withCString { ptr in
            keyEvent.text = ptr
            return ghostty_surface_key(surface, keyEvent)
        }
    }

    // MARK: - Mods (cmux §7194-7217)

    private func modsFromEvent(_ event: NSEvent) -> ghostty_input_mods_e {
        modsFromFlags(event.modifierFlags)
    }

    private func modsFromFlags(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.control) { mods |= GHOSTTY_MODS_CTRL.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        if flags.contains(.command) { mods |= GHOSTTY_MODS_SUPER.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    /// Consumed mods are modifiers that were used for text translation. Control
    /// and Command never contribute to text translation, so they're excluded.
    /// cmux §7210-7217.
    fileprivate func consumedModsFromFlags(_ flags: NSEvent.ModifierFlags) -> ghostty_input_mods_e {
        var mods = GHOSTTY_MODS_NONE.rawValue
        if flags.contains(.shift) { mods |= GHOSTTY_MODS_SHIFT.rawValue }
        if flags.contains(.option) { mods |= GHOSTTY_MODS_ALT.rawValue }
        return ghostty_input_mods_e(rawValue: mods)
    }

    // MARK: - Mouse / scroll (D-c.2d)

    override func mouseDown(with event: NSEvent) {
        // Clicks should always take first responder so keyboard input routes
        // here even if the user tabbed around SwiftUI elements.
        window?.makeFirstResponder(self)

        guard let surface = runtimeSurface else { return }
        let point = convert(event.locationInWindow, from: nil)
        // Only update position on first click so double-click selection isn't
        // jittered by a second mouse_pos at a slightly different point (cmux §7461).
        if event.clickCount == 1 {
            ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
    }

    override func mouseUp(with event: NSEvent) {
        guard let surface = runtimeSurface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, modsFromEvent(event))
    }

    override func mouseDragged(with event: NSEvent) {
        guard let surface = runtimeSurface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let surface = runtimeSurface else {
            super.rightMouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    }

    override func rightMouseUp(with event: NSEvent) {
        guard let surface = runtimeSurface else {
            super.rightMouseUp(with: event)
            return
        }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_RIGHT, modsFromEvent(event))
    }

    override func otherMouseDown(with event: NSEvent) {
        guard let surface = runtimeSurface else { return }
        let point = convert(event.locationInWindow, from: nil)
        ghostty_surface_mouse_pos(surface, point.x, bounds.height - point.y, modsFromEvent(event))
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_MIDDLE, modsFromEvent(event))
    }

    override func otherMouseUp(with event: NSEvent) {
        guard let surface = runtimeSurface else { return }
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_MIDDLE, modsFromEvent(event))
    }

    override func scrollWheel(with event: NSEvent) {
        guard let surface = runtimeSurface else { return }
        var x = event.scrollingDeltaX
        var y = event.scrollingDeltaY
        let precision = event.hasPreciseScrollingDeltas
        if precision {
            x *= 2
            y *= 2
        }

        // ghostty_input_scroll_mods_t packs: bit 0 = precision, bits 1..n = momentum.
        // cmux §8312-8334.
        var mods: Int32 = 0
        if precision {
            mods |= 0b0000_0001
        }

        let momentum: Int32
        switch event.momentumPhase {
        case .began:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_BEGAN.rawValue)
        case .stationary:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_STATIONARY.rawValue)
        case .changed:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CHANGED.rawValue)
        case .ended:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_ENDED.rawValue)
        case .cancelled:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_CANCELLED.rawValue)
        case .mayBegin:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_MAY_BEGIN.rawValue)
        default:
            momentum = Int32(GHOSTTY_MOUSE_MOMENTUM_NONE.rawValue)
        }
        mods |= momentum << 1

        ghostty_surface_mouse_scroll(
            surface,
            x,
            y,
            ghostty_input_scroll_mods_t(mods)
        )
    }

    // MARK: - Text extraction helpers (cmux §7237-7291)

    /// Extract the characters for a key event with control-character handling.
    /// When control is pressed we get the character without the control modifier
    /// so Ghostty's KeyEncoder can apply its own control encoding.
    private func textForKeyEvent(_ event: NSEvent) -> String? {
        guard let chars = event.characters, !chars.isEmpty else { return nil }

        if chars.count == 1, let scalar = chars.unicodeScalars.first {
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if isControlCharacterScalar(scalar) {
                if flags.contains(.control) {
                    return event.characters(byApplyingModifiers: event.modifierFlags.subtracting(.control))
                }
                // AppKit sometimes reports Shift+` as a bare ESC even though the
                // physical key should produce "~".
                if scalar.value == 0x1B,
                   flags == [.shift],
                   event.charactersIgnoringModifiers == "`" {
                    return "~"
                }
            }
            // Private-use codepoints (function keys) must not be sent as text.
            if scalar.value >= 0xF700 && scalar.value <= 0xF8FF {
                return nil
            }
        }

        return chars
    }

    /// Fallback unshifted codepoint. cmux uses a KeyboardLayout helper that
    /// consults the Core Foundation layout cache; kanbario's MVP relies on
    /// AppKit's byApplyingModifiers:[] alone, which covers US / ISO layouts.
    private func unshiftedCodepointFromEvent(_ event: NSEvent) -> UInt32 {
        guard let chars = (event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? event.characters),
              let scalar = chars.unicodeScalars.first else { return 0 }
        return scalar.value
    }

    private func isControlCharacterScalar(_ scalar: UnicodeScalar) -> Bool {
        scalar.value < 0x20 || scalar.value == 0x7F
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }

        terminalSurface?.attachToView(self)

        if let surface = terminalSurface?.surface,
           let displayID = window.screen?.displayID,
           displayID != 0 {
            ghostty_surface_set_display_id(surface, displayID)
        }

        superview?.layoutSubtreeIfNeeded()
        layoutSubtreeIfNeeded()
        updateSurfaceSize()
    }

    override func layout() {
        super.layout()
        updateSurfaceSize()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        updateSurfaceSize()
    }

    private func updateSurfaceSize() {
        guard let terminalSurface, terminalSurface.isLive else { return }
        let xScale = window?.backingScaleFactor ?? layer?.contentsScale ?? NSScreen.main?.backingScaleFactor ?? 1.0
        let yScale = xScale
        let backing = convertToBacking(NSRect(origin: .zero, size: bounds.size)).size
        terminalSurface.updateSize(
            width: bounds.width,
            height: bounds.height,
            xScale: xScale,
            yScale: yScale,
            backingSize: backing
        )
    }

    // GhosttySurfaceOwning — libghostty asked us to close; forward to the
    // owner (kanban board drives actual task-state transitions).
    func ghosttyDidRequestClose(needsConfirm: Bool) {
        onCloseRequested?(needsConfirm)
    }

    /// Explicit lifecycle hook — called by the SwiftUI coordinator when the
    /// hosting task disappears (e.g., kanban card removed or moved to done).
    @MainActor
    func teardown() {
        terminalSurface?.teardown()
        terminalSurface = nil
    }
}

// MARK: - NSTextInputClient (D-c.2c — IME / 日本語入力)
//
// Layout follows cmux §11739-12189 with kanbario-specific trims:
// - No DEBUG timing instrumentation
// - No cmux-specific telemetry (cmuxWriteChildExitProbe, dlog)
// - No AX / dictation-specific sanitizeExternalCommittedText path
//   (committed text from insertText goes straight to sendTextToSurface)
// - readSelectionSnapshot / visibleDocumentRectInScreenCoordinates are stubbed
//   to defaults since we don't (yet) surface selection / scroll state back to
//   AppKit. This matters for dictation / accessibility but not for plain IME.

extension GhosttyNSView: NSTextInputClient {
    /// Deliver committed text to libghostty as a synthetic key event so shells
    /// keep normal interactive semantics (Return executes, Tab completes, etc.).
    /// cmux §11744-11827 verbatim minus DEBUG instrumentation.
    fileprivate func sendTextToSurface(_ chars: String) {
        guard let surface = runtimeSurface else { return }

        var bufferedText = ""
        var previousWasCR = false

        func flushBufferedText() {
            guard !bufferedText.isEmpty else { return }
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = GHOSTTY_ACTION_PRESS
            keyEvent.keycode = 0
            keyEvent.mods = GHOSTTY_MODS_NONE
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.unshifted_codepoint = 0
            keyEvent.composing = false
            bufferedText.withCString { ptr in
                keyEvent.text = ptr
                _ = ghostty_surface_key(surface, keyEvent)
            }
            bufferedText.removeAll(keepingCapacity: true)
        }

        func sendControlKey(_ keycode: UInt32) {
            var keyEvent = ghostty_input_key_s()
            keyEvent.action = GHOSTTY_ACTION_PRESS
            keyEvent.keycode = keycode
            keyEvent.mods = GHOSTTY_MODS_NONE
            keyEvent.consumed_mods = GHOSTTY_MODS_NONE
            keyEvent.unshifted_codepoint = 0
            keyEvent.composing = false
            keyEvent.text = nil
            _ = ghostty_surface_key(surface, keyEvent)
        }

        for scalar in chars.unicodeScalars {
            switch scalar.value {
            case 0x0A:
                if !previousWasCR {
                    flushBufferedText()
                    sendControlKey(0x24) // kVK_Return
                }
                previousWasCR = false
            case 0x0D:
                flushBufferedText()
                sendControlKey(0x24) // kVK_Return
                previousWasCR = true
            case 0x09:
                flushBufferedText()
                sendControlKey(0x30) // kVK_Tab
                previousWasCR = false
            case 0x1B:
                flushBufferedText()
                sendControlKey(0x35) // kVK_Escape
                previousWasCR = false
            default:
                bufferedText.unicodeScalars.append(scalar)
                previousWasCR = false
            }
        }
        flushBufferedText()
    }

    func hasMarkedText() -> Bool {
        markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange(location: NSNotFound, length: 0) }
        return NSRange(location: 0, length: markedText.length)
    }

    func selectedRange() -> NSRange {
        NSRange(location: 0, length: 0)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        switch string {
        case let v as NSAttributedString:
            markedText = NSMutableAttributedString(attributedString: v)
        case let v as String:
            markedText = NSMutableAttributedString(string: v)
        default:
            break
        }
        // When called outside a keyDown (e.g. IM selector change while composing)
        // we push the preedit immediately. Inside keyDown, keyDown's own
        // syncPreedit call at the end takes care of it.
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        if markedText.length > 0 {
            markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    /// Push the current `markedText` to libghostty as preedit bytes so it can
    /// render the IME composition overlay aligned to the cursor cell.
    /// cmux §12002-12029.
    fileprivate func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface = runtimeSurface else { return }

        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8CString.count
            if len > 0 {
                str.withCString { ptr in
                    // -1 strips the null terminator; ghostty_surface_preedit
                    // takes a byte length.
                    ghostty_surface_preedit(surface, ptr, UInt(len - 1))
                }
            }
        } else if clearIfNeeded {
            ghostty_surface_preedit(surface, nil, 0)
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        // kanbario MVP doesn't surface the terminal's selection back to AppKit.
        // Dictation / AX readers may request substrings; returning nil tells
        // them to back off, which is correct for our use case (no accessible
        // selection content yet).
        _ = range
        _ = actualRange
        return nil
    }

    func characterIndex(for point: NSPoint) -> Int {
        _ = point
        return 0
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        _ = range
        _ = actualRange
        guard let window else {
            return NSRect(x: frame.origin.x, y: frame.origin.y, width: 0, height: 0)
        }

        // Ask libghostty where the IME cursor should anchor. This positions
        // Kotoeri / Google IME candidate windows at the terminal cursor.
        var x: Double = 0
        var y: Double = 0
        var w: Double = cellSize.width
        var h: Double = cellSize.height
        if let surface = runtimeSurface {
            ghostty_surface_ime_point(surface, &x, &y, &w, &h)
        }

        // Ghostty uses top-left origin; AppKit uses bottom-left.
        let fallbackHeight = h > 0 ? h : 18 // reasonable default line height
        let viewRect = NSRect(
            x: x,
            y: frame.size.height - y,
            width: w,
            height: max(h, fallbackHeight)
        )
        let windowRect = convert(viewRect, to: nil)
        return window.convertToScreen(windowRect)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        _ = replacementRange

        var chars = ""
        switch string {
        case let v as NSAttributedString:
            chars = v.string
        case let v as String:
            chars = v
        default:
            return
        }

        // IME confirmation: composition is committed as regular text, so drop
        // the preedit state first.
        unmarkText()

        guard !chars.isEmpty else { return }

        // Inside a keyDown, accumulate and let keyDown send one consolidated
        // key event. Outside (AX / dictation), commit directly.
        if keyTextAccumulator != nil {
            keyTextAccumulator?.append(chars)
            return
        }

        sendTextToSurface(chars)
    }

    /// Legacy NSResponder signature (used by some AX paths). Routes through the
    /// modern `insertText(_:replacementRange:)` so we have one code path.
    override func insertText(_ insertString: Any) {
        insertText(insertString, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
}

// MARK: - SwiftUI wrapper

/// SwiftUI bridge. One `GhosttyTerminalView` maps 1:1 to a kanbario task — the
/// `TerminalSurface` instance is passed in by the caller so session lifetime
/// matches the kanban card, not the SwiftUI view identity.
struct GhosttyTerminalView: NSViewRepresentable {
    let terminalSurface: TerminalSurface
    var onCloseRequested: ((_ needsConfirm: Bool) -> Void)?

    func makeNSView(context: Context) -> GhosttyNSView {
        let view = GhosttyNSView(terminalSurface: terminalSurface)
        view.onCloseRequested = onCloseRequested
        return view
    }

    func updateNSView(_ nsView: GhosttyNSView, context: Context) {
        nsView.onCloseRequested = onCloseRequested
    }

    static func dismantleNSView(_ nsView: GhosttyNSView, coordinator: ()) {
        MainActor.assumeIsolated {
            nsView.teardown()
        }
    }
}
