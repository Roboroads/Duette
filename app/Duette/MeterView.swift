import Foundation
import SwiftUI

/// Turns the engine's linear peak into the length of a level bar.
enum MeterScale {
    /// The bottom of the bar.
    static let floorDecibels: Float = -60

    enum Zone: Equatable {
        case normal
        case loud
        case clipping
    }

    /// 0 for silence (and anything below -60 dB), 1 for full scale and above.
    static func fraction(peak: Float) -> Float {
        guard peak.isFinite, peak > 0 else { return 0 }
        let decibels = 20 * log10(peak)
        return min(max((decibels - floorDecibels) / -floorDecibels, 0), 1)
    }

    static func zone(fraction: Float) -> Zone {
        if fraction >= 0.98 { return .clipping }
        if fraction >= 0.8 { return .loud }
        return .normal
    }
}

/// Smooths a level for display: it jumps up at once and falls back at a fixed speed, so a short
/// peak is still visible at 30 frames per second.
final class MeterFollower {
    private let fallPerSecond: Float
    private var value: Float = 0
    private var lastUpdate: Date?

    /// - Parameter fallPerSecond: how much of the full bar the level drops per second.
    init(fallPerSecond: Float = 1.2) {
        self.fallPerSecond = fallPerSecond
    }

    /// The bar length (0...1) to show for `peak` at `date`.
    func update(peak: Float, at date: Date) -> Float {
        let target = MeterScale.fraction(peak: peak)
        var elapsed: Float = 0
        if let last = lastUpdate {
            elapsed = Float(max(date.timeIntervalSince(last), 0))
            lastUpdate = max(last, date)
        } else {
            lastUpdate = date
        }
        value = max(target, value - fallPerSecond * elapsed)
        return value
    }
}

/// A level bar. The colour is not the only cue: the accessibility value says the level in words.
struct MeterView: View {
    let title: String
    let peak: Float
    let date: Date
    @State private var follower = MeterFollower()

    var body: some View {
        let fraction = follower.update(peak: peak, at: date)
        return MeterBar(fraction: fraction)
            .accessibilityElement()
            .accessibilityLabel("\(title) level")
            .accessibilityValue(Self.words(for: fraction))
    }

    static func words(for fraction: Float) -> String {
        switch MeterScale.zone(fraction: fraction) {
        case .clipping: return "too loud"
        case .loud: return "loud"
        case .normal: return fraction < 0.05 ? "silent" : "good"
        }
    }
}

/// The drawing of a level bar, from a length between 0 and 1.
struct MeterBar: View {
    let fraction: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.12))
                Capsule()
                    .fill(color)
                    .frame(width: max(proxy.size.width * CGFloat(fraction), fraction > 0 ? 4 : 0))
            }
        }
        .frame(height: 8)
    }

    private var color: Color {
        switch MeterScale.zone(fraction: fraction) {
        case .normal: return .green
        case .loud: return .orange
        case .clipping: return .red
        }
    }
}

#if DEBUG
struct MeterBar_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 12) {
            MeterBar(fraction: 0)
            MeterBar(fraction: 0.4)
            MeterBar(fraction: 0.85)
            MeterBar(fraction: 1)
        }
        .padding()
        .frame(width: 240)
    }
}
#endif
