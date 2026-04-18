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
