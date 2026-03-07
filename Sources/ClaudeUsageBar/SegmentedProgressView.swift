import SwiftUI

/// A segmented progress bar that fills to `fillFraction` and subdivides that fill
/// proportionally by model family. Hover over a segment to see a tooltip.
struct SegmentedProgressView: View {

    struct Segment: Equatable {
        let label: String
        let color: Color
        /// This segment's share of the filled region (fractions sum to 1.0).
        let fraction: Double
    }

    /// Overall fill fraction 0–1 (e.g. 0.54 for 54% utilization).
    let fillFraction: Double
    let segments: [Segment]

    @State private var hoveredSegment: Segment? = nil

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                // Background track
                Capsule()
                    .fill(Color.secondary.opacity(0.2))

                // Filled segments, clipped to a capsule so edges are rounded
                HStack(spacing: 0) {
                    ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                        Rectangle()
                            .fill(seg.color.opacity(hoveredSegment == seg ? 1.0 : 0.8))
                            .frame(width: max(0, geo.size.width * fillFraction * seg.fraction))
                            .onHover { isHovered in
                                withAnimation(.easeInOut(duration: 0.12)) {
                                    hoveredSegment = isHovered ? seg : nil
                                }
                            }
                    }
                }
                .clipShape(Capsule())
            }
        }
        .frame(height: 8)
        .overlay(alignment: .topTrailing) {
            if let seg = hoveredSegment {
                Text("\(seg.label) · \(Int(round(fillFraction * seg.fraction * 100)))%")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .offset(y: -20)
                    .transition(.opacity)
            }
        }
    }
}
