import SwiftUI

#if canImport(ArtemisSocketSDK)
    import ArtemisSocketSDK
#endif

struct ChartRichTemplate: View {
    @Environment(\.chatStrings) private var strings
    @Environment(\.chatTheme) private var theme
    @State private var selectedIndex: Int?
    let chart: ChartTemplate
    let accentColor: Color

    private var data: [ChartDataPoint] { Array(chart.data.filter { $0.value.isFinite }.prefix(100)) }
    private var palette: TemplatePalette { TemplatePalette(theme: theme) }
    private var spacingScale: CGFloat { theme?.spacingScale ?? 1 }
    private var kind: String { ["line", "pie"].contains(chart.type) ? chart.type : "bar" }
    private static let colors = [
        "#4F46E5", "#059669", "#D97706", "#DC2626", "#7C3AED", "#DB2777", "#2563EB", "#0891B2",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * spacingScale) {
            if let title = chart.title, !title.templateTrimmed.isEmpty {
                Text(verbatim: title)
                    .font(theme?.font(size: 13, weight: .semibold) ?? .system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.text)
                    .accessibilityAddTraits(.isHeader)
            }
            if data.isEmpty {
                Text(strings("No chart data")).templateBody()
            } else {
                chartGraphic
            }
        }
        .padding(.horizontal, 16 * spacingScale)
        .padding(.vertical, 14 * spacingScale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                Color(hexString: theme?.backgroundColor ?? "#FFFFFF")
                Color(hexString: theme?.surfaceColor ?? "#F5F5F5").opacity(0.1)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(palette.border, lineWidth: 1))
    }

    private var chartGraphic: some View {
        GeometryReader { proxy in
            if virtualWidth > 300 {
                ScrollView(.horizontal, showsIndicators: true) {
                    plot.frame(width: virtualWidth * proxy.size.height / 200, height: proxy.size.height)
                }
            } else {
                plot
            }
        }
        .aspectRatio(kind == "pie" ? 1 : 1.5, contentMode: .fit)
        .overlay(alignment: .topTrailing) {
            if let selectedIndex, data.indices.contains(selectedIndex) {
                let point = data[selectedIndex]
                Text(verbatim: "\(point.label): \(RichContentParser.displayString(point.value))")
                    .font(theme?.font(size: 11) ?? .system(size: 11))
                    .foregroundStyle(palette.text)
                    .padding(8)
                    .background(Color(hexString: theme?.backgroundColor ?? "#FFFFFF"))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(palette.border, lineWidth: 1))
                    .allowsHitTesting(false)
            }
        }
        .accessibilityRepresentation {
            VStack(alignment: .leading) {
                Text(strings(kind == "pie" ? "Pie chart" : kind == "line" ? "Line chart" : "Bar chart"))
                ForEach(Array(data.enumerated()), id: \.offset) { _, point in
                    Text(verbatim: "\(point.label): \(RichContentParser.displayString(point.value))")
                }
            }
        }
    }

    // The WebSDK uses 300 × 200 for bar/line charts and 200 × 200 for pie charts.
    // Extend crowded plots horizontally while keeping their labels readable.
    private var virtualWidth: CGFloat {
        switch kind {
        case "pie": return 200
        case "line": return max(300, 40 + CGFloat(max(0, data.count - 1)) * 40)
        default: return max(300, 30 + CGFloat(data.count) * (barWidth + 10))
        }
    }
    private var barWidth: CGFloat { max(20, (260 / CGFloat(max(1, data.count))).rounded(.down) - 10) }
    private var maximum: Double { max(data.map(\.value).max() ?? 1, 1) }

    private var plot: some View {
        Canvas { context, size in
            guard size.width > 0, size.height > 0 else { return }
            var drawing = context
            let scale = size.height / 200
            drawing.scaleBy(x: scale, y: scale)
            switch kind {
            case "pie": drawPie(in: &drawing)
            case "line": drawLine(in: &drawing)
            default: drawBars(in: &drawing)
            }
        }
        .overlay {
            GeometryReader { proxy in
                Color.clear.contentShape(Rectangle())
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 0).onEnded { event in
                            // A scroll over a chart must continue scrolling the transcript/plot.
                            guard abs(event.translation.width) < 8, abs(event.translation.height) < 8 else { return }
                            let index = pointIndex(at: event.location, size: proxy.size)
                            selectedIndex = selectedIndex == index ? nil : index
                        }
                    )
                    .accessibilityHidden(true)
            }
        }
    }

    private func drawBars(in context: inout GraphicsContext) {
        for (index, point) in data.enumerated() {
            let height = 160 * CGFloat(max(0, point.value) / maximum)
            let x = 20 + CGFloat(index) * (barWidth + 10)
            if height > 0 {
                let rect = CGRect(x: x, y: 160 - height, width: barWidth, height: height)
                context.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color(index)))
            }
            drawLabel(point.label, at: x + barWidth / 2, in: &context)
        }
    }

    private func drawLine(in context: inout GraphicsContext) {
        let positions = data.enumerated().map { index, point in
            CGPoint(
                x: 20 + CGFloat(index) / CGFloat(max(1, data.count - 1)) * (virtualWidth - 40),
                y: max(3, 160 * CGFloat(1 - max(0, point.value) / maximum)))
        }
        var path = Path()
        for (index, position) in positions.enumerated() {
            if index == 0 { path.move(to: position) } else { path.addLine(to: position) }
        }
        let lineColor = color(0)
        context.stroke(path, with: .color(lineColor), style: StrokeStyle(lineWidth: 2, lineJoin: .round))
        for (index, position) in positions.enumerated() {
            context.fill(
                Path(ellipseIn: CGRect(x: position.x - 3, y: position.y - 3, width: 6, height: 6)),
                with: .color(lineColor))
            drawLabel(data[index].label, at: position.x, in: &context)
        }
    }

    private func drawPie(in context: inout GraphicsContext) {
        // Normalize first so a sum of large, finite values cannot overflow.
        let weights = data.map { max(0, $0.value) / maximum }
        let total = weights.reduce(0, +)
        guard total > 0 else { return }
        let center = CGPoint(x: 100, y: 100)
        var angle = -90.0
        for (index, weight) in weights.enumerated() where weight > 0 {
            let fraction = weight / total
            let next = angle + fraction * 360
            var slice = Path()
            if fraction >= 1 {
                slice.addEllipse(in: CGRect(x: 20, y: 20, width: 160, height: 160))
            } else {
                slice.move(to: center)
                slice.addArc(
                    center: center, radius: 80, startAngle: .degrees(angle), endAngle: .degrees(next),
                    clockwise: false)
                slice.closeSubpath()
            }
            context.fill(slice, with: .color(color(index)))
            angle = next
        }
    }

    private func drawLabel(_ value: String, at x: CGFloat, in context: inout GraphicsContext) {
        let label = value.count > 8 ? String(value.prefix(7)) + "…" : value
        let text = Text(verbatim: label)
            .font(theme?.font(size: 10) ?? .system(size: 10))
            .foregroundColor(palette.mutedText)
        context.draw(text, at: CGPoint(x: x, y: 180), anchor: .bottom)
    }

    private func color(_ index: Int) -> Color {
        Color(hexString: data[index].color ?? Self.colors[index % Self.colors.count])
    }

    private func pointIndex(at location: CGPoint, size: CGSize) -> Int? {
        guard !data.isEmpty, size.height > 0 else { return nil }
        let scale = size.height / 200
        let position = CGPoint(x: location.x / scale, y: location.y / scale)
        if kind == "pie" {
            let dx = position.x - 100
            let dy = position.y - 100
            guard dx * dx + dy * dy <= 80 * 80 else { return nil }
            let weights = data.map { max(0, $0.value) / maximum }
            let total = weights.reduce(0, +)
            guard total > 0 else { return nil }
            var angle = atan2(Double(dy), Double(dx)) + .pi / 2
            if angle < 0 { angle += 2 * .pi }
            var end = 0.0
            for (index, weight) in weights.enumerated() where weight > 0 {
                end += weight / total * 2 * .pi
                if angle <= end { return index }
            }
            return nil
        }
        guard position.x >= 10, position.x <= virtualWidth - 10,
            position.y >= 0, position.y <= 190
        else { return nil }
        let index: Int
        if kind == "line" {
            index = Int(((position.x - 20) / (virtualWidth - 40) * CGFloat(max(1, data.count - 1))).rounded())
        } else {
            index = Int(((position.x - 20) / (barWidth + 10)).rounded(.down))
        }
        return min(max(0, index), data.count - 1)
    }
}
