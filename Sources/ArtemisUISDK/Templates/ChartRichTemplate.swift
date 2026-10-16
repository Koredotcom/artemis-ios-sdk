#if canImport(ArtemisSocketSDK)
import ArtemisSocketSDK
#endif
import SwiftUI

struct ChartRichTemplate: View {
    let chart: ChartTemplate
    let accentColor: Color
    private var data: [ChartDataPoint] { Array(chart.data.filter { $0.value.isFinite }.prefix(100)) }
    private let palette: [Color] = [.blue, .green, .orange, .purple, .pink]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title = chart.title { Text(title).templateTitle() }
            if data.isEmpty {
                Text("No chart data").templateBody()
            } else {
                Canvas { context, size in
                    let maximum = max(data.map(\.value).max() ?? 1, 1)
                    if chart.type == "pie" {
                        let weights = data.map { max(0, $0.value) }
                        let sum = weights.reduce(0, +)
                        var angle = -90.0
                        for (i, weight) in weights.enumerated() where sum > 0 {
                            let next = angle + weight / sum * 360
                            var path = Path()
                            let center = CGPoint(x: size.width / 2, y: size.height / 2)
                            path.move(to: center)
                            path.addArc(
                                center: center, radius: min(size.width, size.height) / 2, startAngle: .degrees(angle),
                                endAngle: .degrees(next), clockwise: false)
                            path.closeSubpath()
                            context.fill(path, with: .color(color(i)))
                            angle = next
                        }
                    } else if chart.type == "line" {
                        var path = Path()
                        for (i, point) in data.enumerated() {
                            let position = CGPoint(
                                x: (CGFloat(i) + 0.5) * size.width / CGFloat(data.count),
                                y: size.height * CGFloat(1 - max(0, point.value) / maximum))
                            if i == 0 { path.move(to: position) } else { path.addLine(to: position) }
                        }
                        context.stroke(path, with: .color(accentColor), lineWidth: 3)
                    } else {
                        let slot = size.width / CGFloat(data.count)
                        for (i, point) in data.enumerated() {
                            let height = size.height * CGFloat(max(0, point.value) / maximum)
                            context.fill(
                                Path(
                                    CGRect(
                                        x: CGFloat(i) * slot + 3, y: size.height - height, width: max(1, slot - 6),
                                        height: height)), with: .color(color(i)))
                        }
                    }
                }.frame(height: 160).accessibilityHidden(true)
                ForEach(Array(data.enumerated()), id: \.offset) { i, point in
                    HStack {
                        Circle().fill(color(i)).frame(width: 8, height: 8)
                        Text(point.label)
                        Spacer()
                        Text(RichContentParser.displayString(point.value))
                    }.font(.caption)
                }
            }
        }.templateCard()
    }
    private func color(_ index: Int) -> Color {
        data[index].color.map { Color(hexString: $0) }
            ?? (chart.type == "pie" ? palette[index % palette.count] : accentColor)
    }
}
