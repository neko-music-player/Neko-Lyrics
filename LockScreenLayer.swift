import AppKit

/// Makes a window appear ABOVE the macOS lock screen.
///
/// macOS draws the lock screen in its own layer, so an ordinary window (even at the highest window
/// level) is hidden behind it. The trick is to put the window in a private "space" that the window
/// server ranks above the lock screen. This uses private SkyLight functions, looked up at runtime:
/// if a future macOS renames or removes them, `available` stays false and the app keeps working,
/// it just can't show over the lock screen.
final class LockScreenLayer {
    static let shared = LockScreenLayer()

    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias SpaceCreateFn = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SetLevelFn = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpacesFn = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindowsFn = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32

    /// True when the private functions were found and a space was created.
    private(set) var available = false

    private var connection: Int32 = 0
    private var space: Int32 = 0
    private var addWindows: AddWindowsFn?

    /// Space level that sits above the lock screen (kSLSSpaceAbsoluteLevelNotificationCenterAtScreenLock).
    private let aboveLockScreenLevel: Int32 = 400

    private init() {
        let path = "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight"
        guard let handle = dlopen(path, RTLD_NOW),
              let pMain = dlsym(handle, "SLSMainConnectionID"),
              let pCreate = dlsym(handle, "SLSSpaceCreate"),
              let pLevel = dlsym(handle, "SLSSpaceSetAbsoluteLevel"),
              let pShow = dlsym(handle, "SLSShowSpaces"),
              let pAdd = dlsym(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces")
        else { return }

        let mainConnection = unsafeBitCast(pMain, to: MainConnectionFn.self)
        let createSpace = unsafeBitCast(pCreate, to: SpaceCreateFn.self)
        let setLevel = unsafeBitCast(pLevel, to: SetLevelFn.self)
        let showSpaces = unsafeBitCast(pShow, to: ShowSpacesFn.self)

        connection = mainConnection()
        space = createSpace(connection, 1, 0)          // flag 1: a normal user space (not a desktop)
        _ = setLevel(connection, space, aboveLockScreenLevel)
        _ = showSpaces(connection, [space] as CFArray)
        addWindows = unsafeBitCast(pAdd, to: AddWindowsFn.self)
        available = true
        Self.log("SkyLight loaded: connection=\(connection) space=\(space)")
    }

    /// Moves the window into the above-lock-screen space. Call after the window is on screen
    /// (it needs a real window number). Safe to call repeatedly.
    func attach(_ window: NSWindow) {
        guard available, let addWindows, window.windowNumber > 0 else {
            Self.log("attach skipped: available=\(available) windowNumber=\(window.windowNumber)")
            return
        }
        let result = addWindows(connection, space, [window.windowNumber] as CFArray, 7)
        Self.log("attach window \(window.windowNumber) to space \(space) -> \(result)")
    }

    /// Where the lock-screen diagnostics go: ~/Library/Application Support/NekoLyrics/lockscreen.log
    static var logURL: URL {
        AppSupport.directory.appendingPathComponent("lockscreen.log")
    }

    static func log(_ message: String) {
        let line = "\(Date()) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}
