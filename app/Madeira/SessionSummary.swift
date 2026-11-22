// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright 2026 ft7t8drgwf-wq
// Madeira Converter Exception: see LICENSE-EXCEPTION.md

import Foundation
import UIKit

/// (session-summary) One plain line that says how a session ran: frame rate (median, low, share of slow seconds),
/// hitches, memory peak and heat. Step 0 of the auto-tune plan (plans/auto-tune-plan-2026-11-20.md): auto-tune can
/// only suggest a fix for "it played, but badly" once the log says how it played. Our own design.
///
/// Once a second, on the main thread while a game session is up, it reads the frame counter the FPS overlay reads
/// (madeira_shown_frame_count: presented frames without hidden desktop windows), the worst frame interval of that
/// second (madeira_frame_times_us), the memory iOS judges the app on (phys_footprint) and the thermal state. A second
/// with no frame is not counted as slow: under 10 s after the last frame it is a "freeze" second (the game stopped
/// presenting mid-play), later it is "still" (loading, a menu that does not present). Time Madeira is not the active app
/// is counted apart ("away"), and so is a stretch the timer did not run for more than 3 s (a blocked main thread, the app
/// suspended: "unsampled"); neither is ever folded into a frame rate. Frame times come from the layer that presented
/// last (the game's own window in practice). With the frame-time ring off (env.MADEIRA_FRAME_TIMES = 0) the line says
/// "hitches n/a" and no-frame seconds count as still.
/// Every 60 s one `[session-summary] so far` line goes to the log, so a session iOS ends still
/// leaves its numbers in madeira-log.prev.txt; the session's end writes the final line.
///
/// Logs only: nothing on screen, nothing changes in the game. env.MADEIRA_SESSION_SUMMARY = 0 turns it off.
final class SessionSummary {
    static let shared = SessionSummary()
    static var enabled: Bool { MadeiraConfig.flag("MADEIRA_SESSION_SUMMARY") }

    /// What the numbers are made of; a value type so the host check can feed it seconds directly.
    struct Tally: Equatable {
        static let slowFPS = 20
        static let hitchMS = 100
        static let maxFPS = 240
        /// No frame for longer than this after the last one: still (loading, background), not a freeze.
        static let freezeLimitMS = 10_000

        var seconds = 0            // seconds of the session, from the clock
        var stillSeconds = 0       // no frame, and none for 10 s or more
        var freezeSeconds = 0      // no frame, but there was one less than 10 s ago
        var fpsCounts = [Int](repeating: 0, count: maxFPS + 1)   // moving seconds by frame rate (240 = 240 or more)
        var movingSeconds = 0
        var hitches = 0            // frames of 100 ms or more (a stall counts when the frame that ends it arrives)
        var worstFrameMS = 0
        var memoryPeakMB = 0
        var hotSeconds = 0         // seconds at serious or critical
        var hottest = 0            // ProcessInfo.ThermalState raw value
        var awaySeconds = 0        // Madeira not the active app
        var unsampledSeconds = 0   // the timer did not run for more than 3 s
        var frameTimesAvailable = true

        /// One sample covering `elapsed` whole seconds (at least 1). `fps` is the rate over that time.
        /// Time that says nothing about how the game ran.
        mutating func addAway(_ span: Int) { seconds += span; awaySeconds += span }
        mutating func addUnsampled(_ span: Int) { seconds += span; unsampledSeconds += span }

        mutating func add(fps: Int, elapsed: Int, hitches newHitches: Int, worstFrameMS worst: Int,
                          sinceLastFrameMS: Int, memoryMB: Int, thermal: Int) {
            let span = max(elapsed, 1)
            seconds += span
            memoryPeakMB = max(memoryPeakMB, memoryMB)
            hottest = max(hottest, thermal)
            if thermal >= 2 { hotSeconds += span }
            hitches += newHitches
            worstFrameMS = max(worstFrameMS, worst)
            guard fps > 0 else {
                if frameTimesAvailable, sinceLastFrameMS < Self.freezeLimitMS, movingSeconds > 0 { freezeSeconds += span } else { stillSeconds += span }
                return
            }
            fpsCounts[min(fps, Self.maxFPS)] += span
            movingSeconds += span
        }

        /// The frame rate that `perMille`/1000 of the moving seconds are at or below (nearest rank, integer math).
        func percentile(perMille: Int) -> Int {
            guard movingSeconds > 0 else { return 0 }
            let rank = max((perMille * movingSeconds + 999) / 1000, 1)
            var seen = 0
            for (fps, count) in fpsCounts.enumerated() {
                seen += count
                if seen >= rank { return fps }
            }
            return Self.maxFPS
        }

        var slowSeconds: Int { fpsCounts.prefix(Self.slowFPS).reduce(0, +) }

        static func thermalName(_ raw: Int) -> String {
            ["nominal", "fair", "serious", "critical"][min(max(raw, 0), 3)]
        }

        /// The log line: numbers only, and the title the log already names.
        func line(title: String, final: Bool) -> String {
            let slowShare = movingSeconds == 0 ? 0 : (slowSeconds * 100 + movingSeconds / 2) / movingSeconds
            return "[session-summary] \(final ? "end" : "so far") \(title): \(seconds) s, \(movingSeconds) s with frames, "
                + "\(freezeSeconds) s frozen mid-play, \(stillSeconds) s still, \(awaySeconds) s away, \(unsampledSeconds) s unsampled; "
                + "fps median \(percentile(perMille: 500)), low (the 5% slowest seconds are at or below) \(percentile(perMille: 50)), below \(Self.slowFPS) fps \(slowShare)% of the time; "
                + (frameTimesAvailable ? "\(hitches) hitches (a frame of \(Self.hitchMS) ms or more), worst frame \(worstFrameMS) ms; " : "hitches n/a (frame times off); ")
                + "memory peak \(memoryPeakMB) MB; heat \(Self.thermalName(hottest)), serious or worse \(hotSeconds) s"
        }
    }

    private var timer: Timer?
    private var generation = 0
    private var tally = Tally()
    private var title = ""
    private var lastFrames: UInt64 = 0
    private var lastTickNS: UInt64 = 0
    private var intervals = [UInt32](repeating: 0, count: 1024)
    private var active = true
    private var resumeNS: UInt64 = 0       // when Madeira last became the active app (0: it never left)
    private var observers: [NSObjectProtocol] = []

    static func nowNS() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    /// From a session's start (LibraryModel, beside ThermalPacing.begin). Main thread.
    func begin(title: String) {
        stop(log: true, generation: generation)
        guard Self.enabled else { return }
        generation += 1
        self.title = title.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        tally = Tally()
        lastFrames = madeira_shown_frame_count()
        lastTickNS = Self.nowNS(); resumeNS = 0
        active = UIApplication.shared.applicationState == .active
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.sample(); self?.active = false },
            center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.resume() },
        ]
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.sample() }
        t.tolerance = 0.1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    /// From a session's end (LibraryModel, beside ThermalPacing.end). Any thread: the work runs on main, and only
    /// for the session that was running when end was called (a late hop never stops the next session's timer).
    func end() {
        if Thread.isMainThread { stop(log: true, generation: generation); return }
        let expected = generation   // read before the hop: a late hop must not stop the next session
        DispatchQueue.main.async { [self] in stop(log: true, generation: expected) }
    }

    private func stop(log: Bool, generation expected: Int) {
        guard let t = timer, expected == generation else { return }
        t.invalidate()
        timer = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        if log, tally.seconds > 0 { LogStore.shared.log(tally.line(title: title, final: true)) }
    }

    private func sample() {
        let now = Self.nowNS()
        let elapsedNS = now > lastTickNS ? now - lastTickNS : 0
        guard elapsedNS >= 500_000_000 else { return }   // a tick that came early: the next one covers this time too
        let frames = madeira_shown_frame_count()
        let newFrames = frames >= lastFrames ? Int(min(frames - lastFrames, 1_000_000)) : 0
        lastFrames = frames
        let previousTick = lastTickNS
        lastTickNS = now
        // Whole seconds this sample stands for: 1 for a normal tick, more when the timer did not run (main thread
        // blocked, app suspended). The rate is frames over the real elapsed time, never folded into one second.
        let span = max(Int((Double(elapsedNS) / 1_000_000_000).rounded()), 1)
        guard active else { tally.addAway(span); return }
        guard span <= 3 else {   // never fold a long stretch into one rate
            tally.addUnsampled(span); resumeNS = now   // and no frame across it counts as a hitch
            return
        }
        let fps = Int((Double(newFrames) * 1_000_000_000 / Double(elapsedNS)).rounded())

        // Hitches: the frames that ENDED since the previous tick. The newest interval ends at the last frame
        // (now - sinceLast); walking back through the intervals gives each one's end. A 3 s window sees a long frame
        // whose start lies before the previous tick.
        var sinceLastUS: UInt32 = 0
        let n = Int(madeira_frame_times_us(&intervals, Int32(intervals.count), 3000, &sinceLastUS))
        let count = max(0, min(n, intervals.count))
        var end = now &- UInt64(sinceLastUS) * 1000
        var newHitches = 0, worstUS: UInt32 = 0
        var i = count - 1
        while i >= 0, end > previousTick {
            let us = intervals[i]
            if end &- UInt64(us) * 1000 < resumeNS { break }   // a frame that spans time away says nothing about the game
            worstUS = max(worstUS, us)
            if us >= UInt32(Tally.hitchMS * 1000) { newHitches += 1 }
            end = end &- UInt64(us) * 1000
            i -= 1
        }
        // A stall still going on raises the worst frame now (under the freeze limit, so not a load); it is counted as
        // a hitch once, when the frame that ends it shows up in the intervals above.
        // The ring is off (env.MADEIRA_FRAME_TIMES = 0) when frames came but it holds none: no hitch data then.
        if newFrames > 0, count == 0, sinceLastUS == 0 { tally.frameTimesAvailable = false }
        // Since the last frame, but never across time away: a frame that came before the return counts from the return.
        let lastFrameNS = now &- UInt64(sinceLastUS) * 1000
        let sinceUS = lastFrameNS < resumeNS ? UInt32(min((now &- resumeNS) / 1000, UInt64(UInt32.max))) : sinceLastUS
        let sinceLastMS = tally.frameTimesAvailable ? Int(sinceUS / 1000) : Int.max
        if newFrames == 0, sinceLastMS >= Tally.hitchMS, sinceLastMS < Tally.freezeLimitMS { worstUS = max(worstUS, sinceUS) }

        let before = tally.seconds
        tally.add(fps: fps, elapsed: span, hitches: newHitches, worstFrameMS: Int(worstUS / 1000),
                  sinceLastFrameMS: sinceLastMS, memoryMB: Self.footprintMB(),
                  thermal: ProcessInfo.processInfo.thermalState.rawValue)
        if tally.seconds / 60 > before / 60 { LogStore.shared.log(tally.line(title: title, final: false)) }
    }

    /// Back to the active app: the time away was booked when it resigned and by the samples since; start counting afresh.
    private func resume() {
        guard timer != nil else { return }
        sample()                                   // books the stretch since the last sample as away
        active = true
        lastTickNS = Self.nowNS()
        resumeNS = lastTickNS
        lastFrames = madeira_shown_frame_count()
    }

    /// phys_footprint, the number iOS ends the app on (as FPSOverlay reads it).
    static func footprintMB() -> Int {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return kr == KERN_SUCCESS ? Int(info.phys_footprint / (1024 * 1024)) : 0
    }
}
