//
//  Ext+NSScreen.swift
//  ClaudeIsland
//
//  Extensions for NSScreen to detect notch and built-in display
//

import AppKit

extension NSScreen {
    /// Best-effort menu bar height for this screen.
    /// Uses `frame` vs `visibleFrame` delta, falling back to system thickness.
    var menuBarHeight: CGFloat {
        let computed = max(0, frame.maxY - visibleFrame.maxY)
        if computed > 0 { return computed }
        return NSStatusBar.system.thickness
    }

    /// Returns the size of the notch on this screen (pixel-perfect using macOS APIs)
    var notchSize: CGSize {
        // On non-notch displays `safeAreaInsets.top` is often 0, but the menu bar still exists.
        // Use the menu bar height so the "notch" never exceeds the menu bar when on an external display.
        let notchHeight = safeAreaInsets.top > 0 ? safeAreaInsets.top : menuBarHeight
        let fullWidth = frame.width
        let leftPadding = auxiliaryTopLeftArea?.width ?? 0
        let rightPadding = auxiliaryTopRightArea?.width ?? 0

        guard leftPadding > 0, rightPadding > 0 else {
            // Fallback if auxiliary areas unavailable
            return CGSize(width: 180, height: notchHeight)
        }

        // +4 to match boring.notch's calculation for proper alignment
        let notchWidth = fullWidth - leftPadding - rightPadding + 4
        return CGSize(width: notchWidth, height: notchHeight)
    }

    /// Whether this is the built-in display
    var isBuiltinDisplay: Bool {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else {
            return false
        }
        return CGDisplayIsBuiltin(screenNumber) != 0
    }

    /// The built-in display (with notch on newer MacBooks)
    static var builtin: NSScreen? {
        if let builtin = screens.first(where: { $0.isBuiltinDisplay }) {
            return builtin
        }
        return NSScreen.main
    }

    /// Whether this screen has a physical notch (camera housing)
    var hasPhysicalNotch: Bool {
        safeAreaInsets.top > 0
    }
}
