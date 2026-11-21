// FineTune/Views/Components/FrequencyResponseGraphView.swift
import SwiftUI

/// Interactive real-time frequency response graph (20 Hz – 20 kHz, log scale).
/// Renders a smooth filled curve, an optional secondary comparison/base curve,
/// and optional draggable parametric EQ band handles.
struct FrequencyResponseGraphView: View {
    enum Highlight: Equatable {
        case primary
        case secondary
    }

    enum Mode: String, CaseIterable, Identifiable {
        case overlay
        case difference
        var id: Self { self }
    }

    let primaryCurve: [FrequencyResponsePoint]
    var secondaryCurve: [FrequencyResponsePoint]? = nil
    var primaryColor: Color = DesignTokens.Colors.accentPrimary
    var secondaryColor: Color = Color(nsColor: .systemOrange).opacity(0.85)
    var primaryLabel: String? = nil
    var secondaryLabel: String? = nil
    var maxDB: Double = 18.0
    var height: CGFloat = 110
    var showAxisLabels: Bool = true
    var highlight: Highlight? = nil
    var mode: Mode = .overlay
    var showsLegend: Bool = true

    // Interactive parametric band nodes (optional)
    var bands: [ParametricEQBand] = []
    var selectedBandID: UUID? = nil
    var onSelectBand: ((UUID) -> Void)? = nil
    var onDragBand: ((UUID, Double, Float) -> Void)? = nil

    private let dbGridLines: [Double] = [-12, -6, 0, 6, 12]
    private let axisFrequencyLabels: [(Double, String)] = [
        (50, "50"), (100, "100"), (500, "500"), (1000, "1k"), (5000, "5k"), (10000, "10k")
    ]

    private var differencePoints: [FrequencyResponsePoint] {
        guard let secondary = secondaryCurve, !secondary.isEmpty, !primaryCurve.isEmpty else { return [] }
        return zip(primaryCurve, secondary).map { p, s in
            FrequencyResponsePoint(
                frequency: p.frequency,
                magnitudeDB: s.magnitudeDB - p.magnitudeDB,
                normalizedX: p.normalizedX
            )
        }
    }

    private var effectiveScale: (maxDB: Double, gridLines: [Double], labeledAbsDB: Double?) {
        if mode == .difference {
            let peak = differencePoints.map { abs($0.magnitudeDB) }.max() ?? 0
            let step = max(2.0, ceil(peak))
            let scaledMax = step * 1.25
            var lines: [Double] = [-step, 0, step]
            if step >= 4 {
                let half = step / 2.0
                lines = [-step, -half, 0, half, step]
            }
            return (scaledMax, lines, step)
        }
        let maxLabeled = dbGridLines.filter { $0 > 0 && $0 < maxDB }.max()
        return (maxDB, dbGridLines, maxLabeled)
    }

    var body: some View {
        let scale = effectiveScale
        GeometryReader { geo in
            let rect = plotRect(in: geo.size)
            ZStack(alignment: .topLeading) {
                // Grid + curves via high-FPS Canvas
                Canvas { context, size in
                    let canvasRect = plotRect(in: size)
                    drawGrid(
                        in: &context,
                        rect: canvasRect,
                        maxDB: scale.maxDB,
                        gridLines: scale.gridLines,
                        labeledAbsDB: scale.labeledAbsDB
                    )

                    if mode == .difference {
                        drawDifferenceCurve(differencePoints, in: &context, rect: canvasRect, maxDB: scale.maxDB)
                    } else {
                        let hasSecondary = !(secondaryCurve?.isEmpty ?? true)
                        switch highlight {
                        case .primary:
                            if let secondary = secondaryCurve, !secondary.isEmpty {
                                drawCurve(
                                    secondary, in: &context, rect: canvasRect, maxDB: scale.maxDB,
                                    color: secondaryColor.opacity(0.45), lineWidth: 1.4, dashed: true, filled: false, glow: false
                                )
                            }
                            if !primaryCurve.isEmpty {
                                drawCurve(
                                    primaryCurve, in: &context, rect: canvasRect, maxDB: scale.maxDB,
                                    color: primaryColor, lineWidth: 2.2, dashed: false, filled: !hasSecondary, glow: true
                                )
                            }
                        case .secondary:
                            if !primaryCurve.isEmpty {
                                drawCurve(
                                    primaryCurve, in: &context, rect: canvasRect, maxDB: scale.maxDB,
                                    color: primaryColor.opacity(0.45), lineWidth: 1.4, dashed: false, filled: false, glow: false
                                )
                            }
                            if let secondary = secondaryCurve, !secondary.isEmpty {
                                drawCurve(
                                    secondary, in: &context, rect: canvasRect, maxDB: scale.maxDB,
                                    color: secondaryColor, lineWidth: 2.2, dashed: true, filled: false, glow: true
                                )
                            }
                        case nil:
                            if let secondary = secondaryCurve, !secondary.isEmpty {
                                drawCurve(
                                    secondary, in: &context, rect: canvasRect, maxDB: scale.maxDB,
                                    color: secondaryColor, lineWidth: 1.4, dashed: true, filled: false, glow: false
                                )
                            }
                            if !primaryCurve.isEmpty {
                                drawCurve(
                                    primaryCurve, in: &context, rect: canvasRect, maxDB: scale.maxDB,
                                    color: primaryColor, lineWidth: 1.8, dashed: false, filled: !hasSecondary, glow: false
                                )
                            }
                        }
                    }
                }

                // Interactive draggable band handles
                ForEach(Array(bands.enumerated()), id: \.element.id) { index, band in
                    let pos = pointForBand(band, in: rect, maxDB: scale.maxDB)
                    let isSelected = band.id == selectedBandID
                    bandHandle(index: index + 1, band: band, isSelected: isSelected)
                        .position(pos)
                        .zIndex(isSelected ? 10 : Double(index))
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    onSelectBand?(band.id)
                                    let nx = Double((value.location.x - rect.minX) / max(1, rect.width))
                                    let freq = FrequencyResponseCurve.frequency(forNormalizedX: nx)
                                    let ny = Double((rect.midY - value.location.y) / max(1, rect.height / 2))
                                    let gain = Float(ny * scale.maxDB)
                                    onDragBand?(
                                        band.id,
                                        ParametricEQBand.clampedFrequency(freq),
                                        ParametricEQBand.clampedGain(gain)
                                    )
                                }
                        )
                }

                // Optional compact legend in top-right
                if showsLegend && (primaryLabel != nil || secondaryLabel != nil) {
                    HStack(spacing: 8) {
                        if let primaryLabel {
                            legendChip(label: primaryLabel, color: primaryColor, dashed: false)
                        }
                        if let secondaryLabel {
                            legendChip(label: secondaryLabel, color: secondaryColor, dashed: true)
                        }
                    }
                    .padding(.top, 4)
                    .padding(.trailing, 6)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .frame(height: height)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DesignTokens.Colors.recessedBackground)
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(DesignTokens.Colors.separator, lineWidth: 0.5)
                }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: bands.isEmpty ? .ignore : .contain)
        .accessibilityLabel("Frequency response graph")
    }

    // MARK: - Geometry

    private func plotRect(in size: CGSize) -> CGRect {
        let left: CGFloat = showAxisLabels ? 24 : 6
        let right: CGFloat = 6
        let top: CGFloat = 6
        let bottom: CGFloat = showAxisLabels ? 16 : 6
        return CGRect(
            x: left,
            y: top,
            width: max(10, size.width - left - right),
            height: max(10, size.height - top - bottom)
        )
    }

    private func yPosition(forDB db: Double, in rect: CGRect, maxDB: Double) -> CGFloat {
        let clamped = max(-maxDB, min(maxDB, db))
        let fraction = (maxDB - clamped) / (2.0 * maxDB)
        return rect.minY + CGFloat(fraction) * rect.height
    }

    private func pointForBand(_ band: ParametricEQBand, in rect: CGRect, maxDB: Double) -> CGPoint {
        let nx = FrequencyResponseCurve.normalizedX(forFrequency: band.frequency)
        let x = rect.minX + CGFloat(nx) * rect.width
        let y = yPosition(forDB: Double(band.gainDB), in: rect, maxDB: maxDB)
        return CGPoint(x: x, y: y)
    }

    // MARK: - Canvas Drawing

    private func drawGrid(
        in context: inout GraphicsContext,
        rect: CGRect,
        maxDB: Double,
        gridLines: [Double],
        labeledAbsDB: Double?
    ) {
        let subtleLine = Color.primary.opacity(0.10)
        let zeroLine = Color.primary.opacity(0.25)

        // Vertical log-frequency grid lines
        for freq in FrequencyResponseCurve.gridFrequencies {
            let x = rect.minX + CGFloat(FrequencyResponseCurve.normalizedX(forFrequency: freq)) * rect.width
            var p = Path()
            p.move(to: CGPoint(x: x, y: rect.minY))
            p.addLine(to: CGPoint(x: x, y: rect.maxY))
            context.stroke(p, with: .color(subtleLine), lineWidth: 0.5)
        }

        // Horizontal dB grid lines
        for db in gridLines where abs(db) < maxDB {
            let y = yPosition(forDB: db, in: rect, maxDB: maxDB)
            var p = Path()
            p.move(to: CGPoint(x: rect.minX, y: y))
            p.addLine(to: CGPoint(x: rect.maxX, y: y))
            context.stroke(p, with: .color(db == 0 ? zeroLine : subtleLine), lineWidth: db == 0 ? 1.0 : 0.5)

            let shouldLabel = db == 0 || (labeledAbsDB != nil && abs(abs(db) - labeledAbsDB!) < 0.001)
            if showAxisLabels && shouldLabel {
                let label = db > 0 ? "+\(Int(round(db)))" : "\(Int(round(db)))"
                let text = Text(label).font(DesignTokens.Typography.eqLabel).foregroundColor(.secondary)
                context.draw(text, at: CGPoint(x: rect.minX - 11, y: y), anchor: .center)
            }
        }

        if showAxisLabels {
            for (freq, label) in axisFrequencyLabels {
                let x = rect.minX + CGFloat(FrequencyResponseCurve.normalizedX(forFrequency: freq)) * rect.width
                let text = Text(label).font(DesignTokens.Typography.eqLabel).foregroundColor(.secondary)
                context.draw(text, at: CGPoint(x: x, y: rect.maxY + 8), anchor: .center)
            }
        }
    }

    private func buildPath(for points: [FrequencyResponsePoint], in rect: CGRect, maxDB: Double) -> Path {
        var path = Path()
        for (i, pt) in points.enumerated() {
            let x = rect.minX + CGFloat(pt.normalizedX) * rect.width
            let y = yPosition(forDB: pt.magnitudeDB, in: rect, maxDB: maxDB)
            if i == 0 {
                path.move(to: CGPoint(x: x, y: y))
            } else {
                path.addLine(to: CGPoint(x: x, y: y))
            }
        }
        return path
    }

    private func drawCurve(
        _ points: [FrequencyResponsePoint],
        in context: inout GraphicsContext,
        rect: CGRect,
        maxDB: Double,
        color: Color,
        lineWidth: CGFloat,
        dashed: Bool,
        filled: Bool,
        glow: Bool
    ) {
        guard points.count >= 2 else { return }

        let strokePath = buildPath(for: points, in: rect, maxDB: maxDB)

        if filled {
            let zeroY = yPosition(forDB: 0, in: rect, maxDB: maxDB)
            var fillPath = strokePath
            let lastX = rect.minX + CGFloat(points.last!.normalizedX) * rect.width
            let firstX = rect.minX + CGFloat(points.first!.normalizedX) * rect.width
            fillPath.addLine(to: CGPoint(x: lastX, y: zeroY))
            fillPath.addLine(to: CGPoint(x: firstX, y: zeroY))
            fillPath.closeSubpath()

            context.fill(
                fillPath,
                with: .linearGradient(
                    Gradient(colors: [color.opacity(0.28), color.opacity(0.05)]),
                    startPoint: CGPoint(x: rect.midX, y: rect.minY),
                    endPoint: CGPoint(x: rect.midX, y: rect.maxY)
                )
            )
        }

        if glow {
            context.drawLayer { layer in
                layer.addFilter(.blur(radius: 4))
                layer.stroke(
                    strokePath,
                    with: .color(Color(nsColor: .systemGreen).opacity(0.55)),
                    lineWidth: 7
                )
            }
        }

        let style = dashed
            ? StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round, dash: [4, 3])
            : StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
        context.stroke(strokePath, with: .color(color), style: style)
    }

    private func drawDifferenceCurve(
        _ points: [FrequencyResponsePoint],
        in context: inout GraphicsContext,
        rect: CGRect,
        maxDB: Double
    ) {
        guard points.count >= 2 else { return }

        let strokePath = buildPath(for: points, in: rect, maxDB: maxDB)
        let zeroY = yPosition(forDB: 0, in: rect, maxDB: maxDB)
        let lastX = rect.minX + CGFloat(points.last!.normalizedX) * rect.width
        let firstX = rect.minX + CGFloat(points.first!.normalizedX) * rect.width

        var areaPath = strokePath
        areaPath.addLine(to: CGPoint(x: lastX, y: zeroY))
        areaPath.addLine(to: CGPoint(x: firstX, y: zeroY))
        areaPath.closeSubpath()

        // Positive region (B louder): above zero line -> orange
        context.drawLayer { layer in
            let aboveRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: max(0, zeroY - rect.minY))
            layer.clip(to: Path(aboveRect))
            layer.fill(areaPath, with: .color(Color(nsColor: .systemOrange).opacity(0.4)))
        }

        // Negative region (A louder): below zero line -> accent blue
        context.drawLayer { layer in
            let belowRect = CGRect(x: rect.minX, y: zeroY, width: rect.width, height: max(0, rect.maxY - zeroY))
            layer.clip(to: Path(belowRect))
            layer.fill(areaPath, with: .color(DesignTokens.Colors.accentPrimary.opacity(0.4)))
        }

        context.stroke(
            strokePath,
            with: .color(Color.primary),
            style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round)
        )
    }

    // MARK: - Band Handle & Legend

    private func bandHandle(index: Int, band: ParametricEQBand, isSelected: Bool) -> some View {
        let typeName: String = switch band.type {
        case .peaking: "Peak"
        case .lowShelf: "Low Shelf"
        case .highShelf: "High Shelf"
        }
        return ZStack {
            if isSelected {
                Circle()
                    .fill(primaryColor.opacity(0.28))
                    .frame(width: 24, height: 24)
            }
            Circle()
                .fill(band.isEnabled ? (isSelected ? primaryColor : Color(nsColor: .controlBackgroundColor)) : Color.secondary.opacity(0.4))
                .frame(width: 18, height: 18)
                .overlay {
                    Circle().strokeBorder(band.isEnabled ? primaryColor : Color.secondary, lineWidth: 1.5)
                }
            Text("\(index)")
                .font(DesignTokens.Typography.eqLabel)
                .foregroundStyle(isSelected && band.isEnabled ? Color.white : Color.primary)
        }
        .frame(width: 26, height: 26)
        .contentShape(Circle())
        .opacity(band.isEnabled ? 1.0 : 0.55)
        .help("\(typeName) · \(Int(round(band.frequency))) Hz · \(String(format: "%+.1f dB", band.gainDB)) · Q \(String(format: "%.2f", band.q))")
        .accessibilityLabel("Band \(index), \(typeName)")
        .accessibilityValue("\(Int(round(band.frequency))) Hz, \(String(format: "%+.1f dB", band.gainDB))")
    }

    private func legendChip(label: String, color: Color, dashed: Bool) -> some View {
        HStack(spacing: 4) {
            CurveSwatch(color: color, dashed: dashed, width: 10, lineWidth: dashed ? 1.5 : 2)
            Text(label)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(DesignTokens.Colors.textSecondary)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color(nsColor: .controlBackgroundColor).opacity(0.75)))
    }
}

/// Compact horizontal line swatch (solid or truly dashed) shared by graphs,
/// legends, A/B slot cards, and profile badges.
struct CurveSwatch: View {
    let color: Color
    var dashed: Bool = false
    var width: CGFloat = 14
    var lineWidth: CGFloat = 2

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let y = size.height / 2
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            let style = dashed
                ? StrokeStyle(lineWidth: lineWidth, lineCap: .round, dash: [3, 2.5])
                : StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            context.stroke(path, with: .color(color), style: style)
        }
        .frame(width: width, height: max(2, lineWidth + 2))
    }
}
