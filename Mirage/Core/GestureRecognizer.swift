import Foundation
import CoreGraphics

/// Turns raw hand joints into gestures.
///
/// Static gestures come from finger extension + thumb/index distance, with
/// hysteresis (a gesture must persist for `holdFrames` analyses before it
/// fires and must disappear for `releaseFrames` before it clears). Dynamic
/// gestures (swipes, wave, two-hand spread/squeeze, clap) use a short
/// positional history per hand.
nonisolated final class GestureRecognizer {

    struct Thresholds: Sendable {
        var pinchDistance: CGFloat = 0.45          // × palmSize
        var extensionRatio: CGFloat = 1.55         // tip-to-wrist vs middleJoint-to-wrist
        var swipeDistance: CGFloat = 0.22          // view units within swipeWindow
        var swipeWindow: TimeInterval = 0.35
        var waveReversals: Int = 3
        var waveWindow: TimeInterval = 1.2
        var spreadDelta: CGFloat = 0.18
        var clapDistance: CGFloat = 0.09
        var holdFrames: Int = 3
        var releaseFrames: Int = 4
        var dynamicCooldown: TimeInterval = 0.8
    }

    var thresholds = Thresholds()

    private struct Sample { var t: TimeInterval; var palm: CGPoint }

    private struct HandMemory {
        var history: [Sample] = []
        var candidate: GestureKind?
        var candidateFrames = 0
        var current: GestureKind?
        var missingFrames = 0
        var currentSince: TimeInterval = 0
        var lastDynamicFire: TimeInterval = 0
        var lastSeen: TimeInterval = 0
    }

    private var memory: [String: HandMemory] = [:]
    private var twoHandDistanceHistory: [Sample] = []
    private var lastTwoHandFire: TimeInterval = 0
    private var lastClap: TimeInterval = 0

    struct Output: Sendable {
        var states: [HandGestureState]
        var events: [GestureEvent]
    }

    func process(_ analysis: FrameAnalysis) -> Output {
        let now = analysis.timestamp
        var states: [HandGestureState] = []
        var events: [GestureEvent] = []

        // Forget hands that vanished for a while.
        for (id, mem) in memory where now - mem.lastSeen > 1.0 { memory[id] = nil; _ = id }

        for hand in analysis.hands {
            var mem = memory[hand.id] ?? HandMemory()
            mem.lastSeen = now
            let palm = hand.palmCenter
            mem.history.append(Sample(t: now, palm: palm))
            mem.history.removeAll { now - $0.t > thresholds.waveWindow }

            let features = Self.features(of: hand, thresholds: thresholds)
            let detected = Self.classify(features)

            // Hysteresis for static gestures.
            if detected == mem.candidate {
                mem.candidateFrames += 1
            } else {
                mem.candidate = detected
                mem.candidateFrames = 1
            }
            if let detected, mem.candidateFrames >= thresholds.holdFrames, mem.current != detected {
                mem.current = detected
                mem.currentSince = now
                mem.missingFrames = 0
                events.append(GestureEvent(kind: detected, side: hand.side, position: palm,
                                           strength: detected == .pinch ? features.pinchStrength : 1, timestamp: now))
            } else if detected == nil || detected != mem.current {
                mem.missingFrames += 1
                if mem.missingFrames >= thresholds.releaseFrames, mem.current != nil, detected != mem.current {
                    mem.current = nil
                }
            } else {
                mem.missingFrames = 0
            }

            // Velocity over the last ~100 ms.
            var velocity = CGVector.zero
            if let old = mem.history.last(where: { now - $0.t >= 0.08 }) ?? mem.history.first, now - old.t > 0.001 {
                let dt = now - old.t
                velocity = CGVector(dx: (palm.x - old.palm.x) / dt, dy: (palm.y - old.palm.y) / dt)
            }

            // Dynamic single-hand gestures.
            if now - mem.lastDynamicFire > thresholds.dynamicCooldown {
                if let swipe = Self.detectSwipe(mem.history, now: now, thresholds: thresholds) {
                    mem.lastDynamicFire = now
                    events.append(GestureEvent(kind: swipe.kind, side: hand.side, position: palm, strength: swipe.strength, timestamp: now))
                } else if features.openness > 0.6, Self.detectWave(mem.history, thresholds: thresholds) {
                    mem.lastDynamicFire = now
                    mem.history.removeAll()
                    events.append(GestureEvent(kind: .wave, side: hand.side, position: palm, timestamp: now))
                }
            }

            states.append(HandGestureState(
                id: hand.id, side: hand.side, staticGesture: mem.current,
                pinchStrength: features.pinchStrength, openness: features.openness,
                extended: features.extended, palmCenter: palm, palmSize: hand.palmSize,
                velocity: velocity, holdDuration: mem.current == nil ? 0 : now - mem.currentSince
            ))
            memory[hand.id] = mem
        }

        // Two-hand gestures.
        if analysis.hands.count >= 2 {
            let a = analysis.hands[0].palmCenter, b = analysis.hands[1].palmCenter
            let d = a.distance(to: b)
            twoHandDistanceHistory.append(Sample(t: now, palm: CGPoint(x: d, y: 0)))
            twoHandDistanceHistory.removeAll { now - $0.t > 0.6 }
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)

            if now - lastTwoHandFire > thresholds.dynamicCooldown,
               let oldest = twoHandDistanceHistory.first, twoHandDistanceHistory.count > 3 {
                let delta = d - oldest.palm.x
                if delta > thresholds.spreadDelta {
                    lastTwoHandFire = now
                    events.append(GestureEvent(kind: .spread, side: .unknown, position: mid, strength: min(1, delta / 0.4), timestamp: now))
                } else if delta < -thresholds.spreadDelta {
                    lastTwoHandFire = now
                    events.append(GestureEvent(kind: .squeeze, side: .unknown, position: mid, strength: min(1, -delta / 0.4), timestamp: now))
                }
            }
            // Clap: palms rushed together and are now nearly touching.
            if d < thresholds.clapDistance, now - lastClap > 1.0,
               let prev = twoHandDistanceHistory.first(where: { now - $0.t > 0.2 }), prev.palm.x > d * 2.5 {
                lastClap = now
                events.append(GestureEvent(kind: .clap, side: .unknown, position: mid, timestamp: now))
            }
        } else {
            twoHandDistanceHistory.removeAll()
        }

        return Output(states: states, events: events)
    }

    func reset() {
        memory.removeAll()
        twoHandDistanceHistory.removeAll()
    }

    // MARK: Features

    struct Features {
        var extended: [Finger]
        var pinchStrength: CGFloat   // 1 = touching
        var openness: CGFloat        // 0 fist ... 1 open
        var thumbUp: Bool
        var thumbIndexClose: Bool
    }

    static func features(of hand: HandSnapshot, thresholds: Thresholds) -> Features {
        let palmSize = hand.palmSize
        guard let wrist = hand.point(.wrist) else {
            return Features(extended: [], pinchStrength: 0, openness: 0.5, thumbUp: false, thumbIndexClose: false)
        }

        var extended: [Finger] = []
        var totalExtension: CGFloat = 0
        for finger in Finger.allCases {
            guard let tip = hand.point(finger.tip), let mid = hand.point(finger.middleJoint) else { continue }
            let tipDist = tip.distance(to: wrist)
            let midDist = max(0.001, mid.distance(to: wrist))
            let ratio = tipDist / midDist
            // Thumb is short; compare against the index knuckle instead.
            let isExtended: Bool
            if finger == .thumb {
                if let indexMCP = hand.point(.indexMCP) {
                    isExtended = tip.distance(to: indexMCP) > palmSize * 0.9
                } else {
                    isExtended = ratio > 1.2
                }
            } else {
                isExtended = ratio > thresholds.extensionRatio
            }
            if isExtended { extended.append(finger) }
            totalExtension += min(1, max(0, (ratio - 1.0) / 1.0))
        }

        var pinch: CGFloat = 0
        var thumbIndexClose = false
        if let t = hand.point(.thumbTip), let i = hand.point(.indexTip) {
            let d = t.distance(to: i) / palmSize
            pinch = max(0, min(1, 1 - d / thresholds.pinchDistance))
            thumbIndexClose = d < thresholds.pinchDistance
        }

        var thumbUp = false
        if let t = hand.point(.thumbTip), let tb = hand.point(.thumbMP) {
            thumbUp = (tb.y - t.y) > palmSize * 0.4 && abs(t.x - tb.x) < palmSize * 0.6
        }

        return Features(extended: extended, pinchStrength: pinch,
                        openness: totalExtension / CGFloat(Finger.allCases.count),
                        thumbUp: thumbUp, thumbIndexClose: thumbIndexClose)
    }

    static func classify(_ f: Features) -> GestureKind? {
        let set = Set(f.extended)
        let nonThumb = set.subtracting([.thumb])

        // Pinch wins when thumb and index touch and the other fingers are relaxed or curled.
        if f.thumbIndexClose && f.pinchStrength > 0.55 && !nonThumb.isSuperset(of: [.middle, .ring, .little]) {
            return .pinch
        }
        if f.thumbIndexClose && nonThumb == [.middle, .ring, .little] { return .okSign }
        if nonThumb.count >= 4 { return .openPalm }
        if nonThumb.isEmpty && !set.contains(.thumb) { return .fist }
        if nonThumb.isEmpty && f.thumbUp { return .thumbsUp }
        if nonThumb == [.index] { return .point }
        if nonThumb == [.index, .middle] { return .peace }
        if nonThumb == [.index, .little] { return .rockOn }
        return nil
    }

    // MARK: Dynamic

    private static func detectSwipe(_ history: [Sample], now: TimeInterval, thresholds: Thresholds) -> (kind: GestureKind, strength: CGFloat)? {
        guard let latest = history.last,
              let start = history.first(where: { now - $0.t <= thresholds.swipeWindow }) else { return nil }
        let dx = latest.palm.x - start.palm.x
        let dy = latest.palm.y - start.palm.y
        let dist = hypot(dx, dy)
        guard dist > thresholds.swipeDistance else { return nil }
        let strength = min(1, dist / (thresholds.swipeDistance * 2))
        if abs(dx) > abs(dy) * 1.4 {
            return (dx > 0 ? .swipeRight : .swipeLeft, strength)
        } else if abs(dy) > abs(dx) * 1.4 {
            return (dy > 0 ? .swipeDown : .swipeUp, strength)
        }
        return nil
    }

    private static func detectWave(_ history: [Sample], thresholds: Thresholds) -> Bool {
        guard history.count > 8 else { return false }
        var reversals = 0
        var lastSign = 0
        var amplitude: CGFloat = 0
        for i in 1..<history.count {
            let dx = history[i].palm.x - history[i - 1].palm.x
            amplitude += abs(dx)
            let sign = dx > 0.004 ? 1 : (dx < -0.004 ? -1 : 0)
            if sign != 0 && lastSign != 0 && sign != lastSign { reversals += 1 }
            if sign != 0 { lastSign = sign }
        }
        return reversals >= thresholds.waveReversals && amplitude > 0.25
    }
}
