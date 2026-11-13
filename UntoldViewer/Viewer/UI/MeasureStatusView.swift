//
//  MeasureStatusView.swift
//  Untold Viewer
//
//  The pill that stays up during a measurement pass, across both spaces,
//  with the step and what it is doing — and, by staying open, keeps the app
//  alive while the main window is hidden. Its window takes the main window's
//  spot (centred at eye level) and is tall and transparent, with the capsule
//  at its top edge, so the capsule floats above the object, which sits at eye
//  level during a pass. `windowHeight` sets how far above.
//

import SwiftUI

struct MeasureStatusView: View {
    private var measurement: MeasurementRun { MeasurementRun.shared }
    /// The transparent window's size, points; the capsule sits at its top.
    static let windowWidth: CGFloat = 480
    static let windowHeight: CGFloat = 560

    var body: some View {
        VStack(spacing: 0) {
            pill
            Spacer(minLength: 0)
        }
        .frame(width: Self.windowWidth, height: Self.windowHeight)
    }

    private var pill: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            HStack(spacing: 12) {
                Image(systemName: measurement.running ? "stopwatch" : "checkmark.circle")
                    .font(.system(size: 18, weight: .semibold))
                VStack(alignment: .leading, spacing: 1) {
                    Text(measurement.step)
                        .font(.system(size: 15, weight: .semibold))
                    Text(measurement.detail(at: context.date))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
        }
        .frame(minWidth: 320, alignment: .leading)
        .glassBackgroundEffect(in: .capsule)
    }
}
