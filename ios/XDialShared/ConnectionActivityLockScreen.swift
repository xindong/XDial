import SwiftUI

/// Lock-screen Live Activity banner. Shared with the app so tests can render it
/// at real banner widths, in both languages and at large text sizes.
///
/// Priority, top to bottom: connection state and elapsed time; the self-check
/// state when it needs attention; the selected scenario (a choice, not a
/// verified exit region); both speeds. A speed value and its unit are one unit
/// and never wrap apart; long text truncates at its own line instead of
/// squeezing the others.
struct XDialActivityLockScreenView: View {
    let state: XDialConnectionAttributes.ContentState
    let tint: Color

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            DialGlyph(filled: state.phase != .working, color: tint)
                .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(state.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                    Spacer(minLength: 4)
                    // WidgetKit's ticking text needs a finite width in the archived
                    // Lock Screen layout. Measuring the timer itself with fixedSize
                    // can push the banner's contents outside the card.
                    Text(verbatim: state.connectedAt == nil ? "…" : "88:88:88")
                        .hidden()
                        .overlay(alignment: .trailing) {
                            XDialElapsedText(connectedAt: state.connectedAt)
                                .foregroundStyle(tint)
                        }
                        .font(.system(.title3, design: .rounded).monospacedDigit())
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if let detail = state.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
                if !state.scenarioName.isEmpty {
                    Text(state.scenarioName)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                }
                if state.connectedAt != nil {
                    // Full units when they fit; otherwise the compact form, never a wrap.
                    ViewThatFits(in: .horizontal) {
                        speeds(compact: false)
                        speeds(compact: true)
                    }
                    .foregroundStyle(.white.opacity(0.75))
                    .padding(.top, 1)
                }
            }
        }
        // Past this size the banner stops gaining legibility and starts dropping lines.
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    private func speeds(compact: Bool) -> some View {
        HStack(spacing: compact ? 10 : 14) {
            XDialSpeedLabel(symbol: "arrow.down", value: state.downloadBytesPerSecond, compact: compact)
            XDialSpeedLabel(symbol: "arrow.up", value: state.uploadBytesPerSecond, compact: compact)
        }
    }
}

/// Elapsed time since connecting; the system refreshes it every second.
struct XDialElapsedText: View {
    let connectedAt: Date?

    var body: some View {
        if let connectedAt {
            Text(timerInterval: connectedAt...Date.distantFuture, countsDown: false)
                .multilineTextAlignment(.trailing)
        } else {
            Text("…")
        }
    }
}

/// One direction of throughput. The arrow, number and unit stay on one line.
struct XDialSpeedLabel: View {
    let symbol: String
    let value: Double?
    var tint: Color?
    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(tint ?? .primary)
            Text(compact ? XDialSpeedFormat.short(value) : XDialSpeedFormat.full(value))
                .font(.system(.footnote, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .contentTransition(.identity)
        }
        .fixedSize()
    }
}
