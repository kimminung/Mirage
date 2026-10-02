import Foundation
import CoreGraphics
import SwiftUI

/// Simulation state for every effect layer. Stepped once per rendered frame
/// (from the Canvas) and fed with the latest analysis + gesture states.
/// All geometry is in view-normalized coordinates (0...1), scaled at draw time.
@MainActor
final class EffectEngine {

    struct Particle {
        var position: CGPoint
        var velocity: CGVector
        var life: CGFloat       // seconds remaining
        var maxLife: CGFloat
        var size: CGFloat
        var colorIndex: Int
        var spin: CGFloat
    }

    struct Ripple {
        var center: CGPoint
        var age: CGFloat
        var maxAge: CGFloat
        var colorIndex: Int
    }

    struct Stroke: Identifiable {
        let id = UUID()
        var points: [CGPoint]
        var colorIndex: Int
        var width: CGFloat
        var bornAt: TimeInterval
    }

    struct Trail {
        var points: [(p: CGPoint, t: TimeInterval)] = []
    }

    struct Burst {
        var text: String
        var position: CGPoint
        var age: CGFloat
    }

    // MARK: State

    private(set) var particles: [Particle] = []
    private(set) var ripples: [Ripple] = []
    private(set) var strokes: [Stroke] = []
    private(set) var trails: [String: Trail] = [:]     // key: handID + joint
    private(set) var bursts: [Burst] = []
    private(set) var kaleidoscopeAngle: CGFloat = 0
    private(set) var paletteOffset = 0
    private(set) var lastStepTime: TimeInterval = 0
    private(set) var frameCount = 0
    private(set) var measuredFPS: Double = 0
    private var fpsWindowStart: TimeInterval = 0
    private var fpsWindowFrames = 0

    private var activeStrokes: [String: UUID] = [:]   // hand -> stroke being drawn
    private var rng = SystemRandomNumberGenerator()
    private var ambientTimer: CGFloat = 0

    var maxParticles = 1800

    // MARK: Step

    /// Advances the simulation. `preset` controls which layers are active.
    func step(now: TimeInterval,
              preset: EffectPreset,
              hands: [HandGestureState],
              analysis: FrameAnalysis?,
              kaleidoscopeOn: Bool) {
        let dt = lastStepTime == 0 ? 1.0 / 60.0 : min(0.05, max(0.001, now - lastStepTime))
        lastStepTime = now
        frameCount += 1

        fpsWindowFrames += 1
        if now - fpsWindowStart >= 1 {
            measuredFPS = Double(fpsWindowFrames) / max(0.001, now - fpsWindowStart)
            fpsWindowFrames = 0
            fpsWindowStart = now
        }

        let intensity = CGFloat(preset.intensity) / 10
        let persistence = CGFloat(preset.persistence) / 10
        let paletteCount = max(1, preset.palette.count)

        // 1. Emit from fingertips.
        if preset.contains(.sparks) || preset.contains(.constellation) {
            for hand in hands {
                guard let snapshot = analysis?.hands.first(where: { $0.id == hand.id }) else { continue }
                let perTip = Int((intensity * 3).rounded(.up))
                for tip in HandJoint.tips {
                    guard let p = snapshot.point(tip) else { continue }
                    for _ in 0..<perTip where particles.count < maxParticles {
                        let angle = CGFloat.random(in: 0..<(2 * .pi), using: &rng)
                        let speed = CGFloat.random(in: 0.02...0.12, using: &rng) * (0.5 + intensity)
                        let inherit = CGVector(dx: hand.velocity.dx * 0.25, dy: hand.velocity.dy * 0.25)
                        particles.append(Particle(
                            position: p,
                            velocity: CGVector(dx: cos(angle) * speed + inherit.dx, dy: sin(angle) * speed + inherit.dy - 0.02),
                            life: CGFloat.random(in: 0.6...1.6, using: &rng) * (0.5 + persistence),
                            maxLife: 1.6,
                            size: CGFloat.random(in: 1.5...4.5, using: &rng),
                            colorIndex: Int.random(in: 0..<paletteCount, using: &rng),
                            spin: CGFloat.random(in: -3...3, using: &rng)
                        ))
                    }
                }
            }
            // Gentle ambient drift so the scene breathes even without hands.
            ambientTimer += dt
            if ambientTimer > 0.08 && particles.count < maxParticles / 3 && hands.isEmpty && (analysis?.body != nil) {
                ambientTimer = 0
                if let body = analysis?.body, let c = body.shoulderCenter {
                    particles.append(Particle(
                        position: CGPoint(x: c.x + CGFloat.random(in: -0.25...0.25, using: &rng), y: c.y + CGFloat.random(in: -0.1...0.4, using: &rng)),
                        velocity: CGVector(dx: 0, dy: -0.03),
                        life: 2.5, maxLife: 2.5, size: 2, colorIndex: Int.random(in: 0..<paletteCount, using: &rng), spin: 0))
                }
            }
        }

        // 2. Forces from gestures (attract / repel).
        var attractors: [(CGPoint, CGFloat)] = []
        var repellers: [(CGPoint, CGFloat)] = []
        for hand in hands {
            guard let g = hand.staticGesture else { continue }
            switch preset.action(for: g) {
            case .attract: attractors.append((hand.palmCenter, hand.palmSize))
            case .repel: repellers.append((hand.palmCenter, hand.palmSize))
            default: break
            }
        }

        // 3. Integrate particles.
        for i in particles.indices {
            var p = particles[i]
            for (c, size) in attractors {
                let d = c - p.position
                let dist = max(0.02, hypot(d.x, d.y))
                let f = (0.9 * size * 10) / (dist * dist + 0.05) * CGFloat(dt)
                p.velocity.dx += d.x / dist * f
                p.velocity.dy += d.y / dist * f
            }
            for (c, size) in repellers {
                let d = p.position - c
                let dist = max(0.02, hypot(d.x, d.y))
                if dist < size * 4 {
                    let f = (1.4 * size * 10) / (dist * dist + 0.05) * CGFloat(dt)
                    p.velocity.dx += d.x / dist * f
                    p.velocity.dy += d.y / dist * f
                }
            }
            // Drag + slight gravity.
            p.velocity.dx *= pow(0.25, CGFloat(dt))
            p.velocity.dy *= pow(0.25, CGFloat(dt))
            p.velocity.dy += 0.012 * CGFloat(dt)
            p.position.x += p.velocity.dx * CGFloat(dt)
            p.position.y += p.velocity.dy * CGFloat(dt)
            p.life -= CGFloat(dt)
            particles[i] = p
        }
        particles.removeAll { $0.life <= 0 || $0.position.x < -0.1 || $0.position.x > 1.1 || $0.position.y > 1.1 || $0.position.y < -0.1 }

        // 4. Trails.
        if preset.contains(.trails) {
            let keep = 0.25 + persistence * 0.9
            for hand in hands {
                guard let snapshot = analysis?.hands.first(where: { $0.id == hand.id }) else { continue }
                for tip in HandJoint.tips {
                    let key = "\(hand.id)-\(tip.rawValue)"
                    var trail = trails[key] ?? Trail()
                    if let p = snapshot.point(tip) {
                        if let last = trail.points.last?.p, last.distance(to: p) < 0.0015 {
                            // Standing still: don't flood the buffer.
                        } else {
                            trail.points.append((p, now))
                        }
                    }
                    trail.points.removeAll { now - $0.t > keep }
                    if trail.points.count > 90 { trail.points.removeFirst(trail.points.count - 90) }
                    trails[key] = trail
                }
            }
            for (key, trail) in trails where trail.points.allSatisfy({ now - $0.t > keep }) { trails[key] = nil }
        } else if !trails.isEmpty {
            trails.removeAll()
        }

        // 5. Light painting: pinch draws.
        if preset.contains(.lightPainting) {
            for hand in hands {
                guard let snapshot = analysis?.hands.first(where: { $0.id == hand.id }),
                      let tip = snapshot.point(.indexTip) else { continue }
                let painting = hand.staticGesture.map { preset.action(for: $0) == .paint } ?? false
                if painting {
                    if let id = activeStrokes[hand.id], let idx = strokes.firstIndex(where: { $0.id == id }) {
                        if strokes[idx].points.last.map({ $0.distance(to: tip) > 0.002 }) ?? true {
                            strokes[idx].points.append(tip)
                        }
                    } else {
                        let stroke = Stroke(points: [tip], colorIndex: (paletteOffset + strokes.count) % paletteCount,
                                            width: 2 + hand.pinchStrength * 5, bornAt: now)
                        strokes.append(stroke)
                        activeStrokes[hand.id] = stroke.id
                    }
                } else {
                    activeStrokes[hand.id] = nil
                }
            }
            // Strokes fade only when persistence is low.
            if preset.persistence < 10 {
                let ttl = 4 + persistence * 40
                strokes.removeAll { now - $0.bornAt > ttl }
            }
            // Hard caps so a long light-painting session can't grow memory without bound.
            if strokes.count > 200 { strokes.removeFirst(strokes.count - 200) }
            var totalPoints = strokes.reduce(0) { $0 + $1.points.count }
            while totalPoints > 20_000, let first = strokes.first {
                totalPoints -= first.points.count
                strokes.removeFirst()
            }
        }

        // 6. Ripples age.
        for i in ripples.indices { ripples[i].age += CGFloat(dt) }
        ripples.removeAll { $0.age >= $0.maxAge }

        // Open palm emits a ripple every ~0.5 s while held.
        if preset.contains(.forceField) {
            for hand in hands where hand.staticGesture == .openPalm {
                let phase = hand.holdDuration.truncatingRemainder(dividingBy: 0.5)
                if phase < dt * 1.1 {
                    ripples.append(Ripple(center: hand.palmCenter, age: 0, maxAge: 1.2,
                                          colorIndex: Int.random(in: 0..<paletteCount, using: &rng)))
                }
            }
        }

        // 7. Kaleidoscope slowly rotates while on.
        if kaleidoscopeOn { kaleidoscopeAngle += CGFloat(dt) * 0.3 }

        // 8. Bursts (HUD labels) age.
        for i in bursts.indices { bursts[i].age += CGFloat(dt) }
        bursts.removeAll { $0.age > 1.4 }
    }

    // MARK: Gesture actions

    func handle(event: GestureEvent, preset: EffectPreset) {
        let action = preset.action(for: event.kind)
        bursts.append(Burst(text: event.kind.displayName, position: event.position, age: 0))
        switch action {
        case .burst: burst(at: event.position, count: 160 * preset.intensity / 5, paletteCount: preset.palette.count)
        case .clearCanvas: strokes.removeAll(); activeStrokes.removeAll()
        case .nextPalette: paletteOffset += 1
        default: break
        }
    }

    func burst(at center: CGPoint, count: Int, paletteCount: Int) {
        for _ in 0..<count where particles.count < maxParticles {
            let angle = CGFloat.random(in: 0..<(2 * .pi), using: &rng)
            let speed = CGFloat.random(in: 0.15...0.7, using: &rng)
            particles.append(Particle(
                position: center,
                velocity: CGVector(dx: cos(angle) * speed, dy: sin(angle) * speed),
                life: CGFloat.random(in: 0.8...2.0, using: &rng), maxLife: 2,
                size: CGFloat.random(in: 2...6, using: &rng),
                colorIndex: Int.random(in: 0..<max(1, paletteCount), using: &rng),
                spin: CGFloat.random(in: -6...6, using: &rng)))
        }
        ripples.append(Ripple(center: center, age: 0, maxAge: 1.0, colorIndex: 0))
    }

    func clearAll() {
        particles.removeAll(); ripples.removeAll(); strokes.removeAll(); trails.removeAll(); bursts.removeAll()
        activeStrokes.removeAll()
    }

    func clearStrokes() {
        strokes.removeAll(); activeStrokes.removeAll()
    }
}
