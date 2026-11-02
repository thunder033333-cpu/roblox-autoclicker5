// DarwinBridge.swift
// Posts CFDarwinNotifyCenter notifications that the dylib inside
// Roblox is listening for. No shared container, no entitlement,
// no app group needed — Darwin notifications are system-wide.

import Foundation

enum DarwinBridge {

    // ── Notification name constants ───────────────────────────
    // Must match the strings registered in AutoClicker.m exactly.
    private static let startKey    = "com.ac.fire.start"
    private static let stopKey     = "com.ac.fire.stop"
    // Interval: "com.ac.interval.<ms>"  e.g. com.ac.interval.50

    // ── Internal post helper ──────────────────────────────────
    private static func post(_ name: String) {
        let nc = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(
            nc,
            CFNotificationName(rawValue: name as CFString),
            nil,      // object: unused in Darwin center
            nil,      // userInfo: Darwin center can't carry data — encode in name
            true      // deliverImmediately
        )
    }

    // ── Public API ────────────────────────────────────────────

    static func start() { post(startKey) }
    static func stop()  { post(stopKey)  }

    static func setInterval(_ ms: Int) {
        // Clamp to range the dylib accepts (5–2000 ms, multiple of 5)
        let clamped = max(5, min(2000, (ms / 5) * 5))
        post("com.ac.interval.\(clamped)")
    }
}
