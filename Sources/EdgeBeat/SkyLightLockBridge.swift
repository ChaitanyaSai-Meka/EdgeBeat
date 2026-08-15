import AppKit
import Darwin
import OSLog

/// Small runtime bridge for the SkyLight APIs used by BoringNotch and other
/// lock-screen utilities. The symbols are resolved dynamically so the app can
/// still launch normally if a future macOS release removes or renames them.
final class SkyLightLockBridge {
    static let shared = SkyLightLockBridge()

    private typealias MainConnectionID = @convention(c) () -> Int32
    private typealias SpaceCreate = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias SpaceSetAbsoluteLevel = @convention(c) (Int32, Int32, Int32) -> Int32
    private typealias ShowSpaces = @convention(c) (Int32, CFArray) -> Int32
    private typealias AddWindows = @convention(c) (Int32, Int32, CFArray, Int32) -> Int32
    private typealias RemoveWindows = @convention(c) (Int32, CFArray, CFArray) -> Int32

    private let logger = Logger(subsystem: "com.chaitanya.edgebeat", category: "sky-light")
    private let handle: UnsafeMutableRawPointer?
    private let connection: Int32
    private let space: Int32
    private let addWindows: AddWindows
    private let removeWindows: RemoveWindows

    private init?() {
        let handle = dlopen(
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
            RTLD_NOW
        )
        guard let handle,
              let mainConnection = Self.symbol(handle, "SLSMainConnectionID", as: MainConnectionID.self),
              let createSpace = Self.symbol(handle, "SLSSpaceCreate", as: SpaceCreate.self),
              let setSpaceLevel = Self.symbol(handle, "SLSSpaceSetAbsoluteLevel", as: SpaceSetAbsoluteLevel.self),
              let showSpaces = Self.symbol(handle, "SLSShowSpaces", as: ShowSpaces.self),
              let addWindows = Self.symbol(handle, "SLSSpaceAddWindowsAndRemoveFromSpaces", as: AddWindows.self),
              let removeWindows = Self.symbol(handle, "SLSRemoveWindowsFromSpaces", as: RemoveWindows.self) else {
            if let handle { dlclose(handle) }
            return nil
        }

        self.handle = handle
        connection = mainConnection()
        space = createSpace(connection, 1, 0)
        self.addWindows = addWindows
        self.removeWindows = removeWindows

        // BoringNotch uses the notification-center-at-lock level so its window
        // is composited into the lock screen without covering authentication UI.
        _ = setSpaceLevel(connection, space, 400)
        _ = showSpaces(connection, [space] as CFArray)
        logger.notice("SkyLight lock-screen space initialized")
    }

    deinit {
        if let handle { dlclose(handle) }
    }

    func delegate(_ window: NSWindow) {
        _ = addWindows(connection, space, [window.windowNumber] as CFArray, 7)
    }

    func undelegate(_ window: NSWindow) {
        _ = removeWindows(connection, [window.windowNumber] as CFArray, [space] as CFArray)
    }

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String,
                                  as type: T.Type) -> T? {
        guard let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: type)
    }
}
