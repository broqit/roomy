import AppKit
import SwiftUI

/// Live readings under the cache total. They only show load and free space.
struct MeterRow: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var disk: DiskMonitor

    static func isVisible(_ settings: AppSettings) -> Bool {
        settings.showCPUMeter || settings.showMemoryMeter || settings.showGPUMeter || settings.showDiskMeter
    }

    private var diskFraction: Double? {
        let total = disk.status.totalBytes
        guard total > 0 else { return nil }
        let used = min(total, max(0, total - disk.status.freeBytes))
        return Double(used) / Double(total)
    }

    private var diskTint: Color? {
        switch disk.pressure {
        case .normal: return nil
        case .low: return .yellow
        case .critical: return .orange
        case .urgent: return .red
        }
    }

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], spacing: 8) {
            if settings.showCPUMeter {
                MeterCell(
                    title: "CPU",
                    fraction: disk.cpuLoad,
                    caption: nil,
                    history: disk.cpuHistory,
                    accessibilityValue: disk.cpuLoad.map { L10n.f("meter.percent", Self.percent($0)) } ?? L10n.t("meter.measuring")
                )
            }
            if settings.showMemoryMeter {
                MeterCell(
                    title: "RAM",
                    fraction: disk.memory?.fraction,
                    caption: disk.memory.map(Self.memoryCaption) ?? "—",
                    history: nil,
                    accessibilityValue: disk.memory.map { L10n.f("meter.used", Self.memoryCaption($0)) } ?? L10n.t("meter.noData")
                )
            }
            if settings.showGPUMeter {
                MeterCell(
                    title: "GPU",
                    fraction: disk.gpuLoad,
                    caption: disk.gpuLoad == nil ? L10n.t("meter.noData") : L10n.t("meter.load"),
                    history: nil,
                    accessibilityValue: disk.gpuLoad.map { L10n.f("meter.percent", Self.percent($0)) } ?? L10n.t("meter.noData")
                )
            }
            if settings.showDiskMeter {
                MeterCell(
                    title: L10n.t("meter.disk"),
                    fraction: diskFraction,
                    caption: L10n.f("meter.free", ByteFormat.string(disk.status.freeBytes)),
                    history: nil,
                    tint: diskTint,
                    accessibilityValue: "\(L10n.f("meter.free", ByteFormat.string(disk.status.freeBytes))), \(disk.pressure.title)"
                )
            }
        }
    }

    static func percent(_ fraction: Double) -> Int {
        Int((min(1, max(0, fraction)) * 100).rounded())
    }

    /// Memory is sold in binary gigabytes. Decimal ByteFormat would show a 16 GB Mac as 17,2 ГБ.
    static func memoryCaption(_ sample: MemorySample) -> String {
        "\(gibibytes(sample.usedBytes))/\(gibibytes(sample.physicalBytes)) \(L10n.t("meter.gb"))"
    }

    private static func gibibytes(_ bytes: Int64) -> String {
        let value = Double(bytes) / 1_073_741_824
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "uk_UA")
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = abs(value - value.rounded()) < 0.05 ? 0 : 1
        return formatter.string(from: NSNumber(value: value)) ?? "\(Int(value.rounded()))"
    }
}

private struct MeterCell: View {
    let title: String
    let fraction: Double?
    /// Nil shows the history sparkline in its place.
    let caption: String?
    let history: [Double]?
    var tint: Color? = nil
    let accessibilityValue: String

    var body: some View {
        HStack(spacing: 10) {
            MeterRing(fraction: fraction, tint: tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                if let history {
                    Sparkline(values: history)
                        .frame(height: 16)
                } else if let caption {
                    Text(caption)
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.primary.opacity(0.05)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }
}

private struct MeterRing: View {
    let fraction: Double?
    var tint: Color? = nil

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private var value: Double { min(1, max(0, fraction ?? 0)) }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.primary.opacity(0.1), lineWidth: 5)
            if fraction != nil {
                Circle()
                    .trim(from: 0, to: value)
                    .stroke(tint ?? MeterTint.color(value), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(fraction.map { "\(MeterRow.percent($0))" } ?? "—")
                .font(.system(size: 14, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(fraction == nil ? Color.secondary : Color.primary)
                .contentTransition(.numericText())
        }
        .frame(width: 42, height: 42)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.6), value: value)
    }
}

private enum MeterTint {
    static func color(_ value: Double) -> Color {
        switch value {
        case ..<0.8: return .accentColor
        case ..<0.92: return .orange
        default: return .red
        }
    }
}

/// CPU load over the last minute, oldest on the left. Scaled to 0...100%, not to the peak.
private struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                if values.count >= 2 {
                    area(in: size)
                        .fill(LinearGradient(
                            colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        ))
                    line(in: size)
                        .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, lineJoin: .round))
                } else {
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: size.height - 0.5))
                        path.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
                    }
                    .stroke(Color.primary.opacity(0.15), lineWidth: 1)
                }
            }
        }
    }

    private func points(in size: CGSize) -> [CGPoint] {
        let step = size.width / CGFloat(max(1, values.count - 1))
        return values.enumerated().map { index, value in
            let clamped = CGFloat(min(1, max(0, value)))
            return CGPoint(x: CGFloat(index) * step, y: size.height - clamped * (size.height - 1.5) - 0.75)
        }
    }

    private func line(in size: CGSize) -> Path {
        Path { path in
            path.addLines(points(in: size))
        }
    }

    private func area(in size: CGSize) -> Path {
        Path { path in
            let points = points(in: size)
            guard let first = points.first, let last = points.last else { return }
            path.move(to: CGPoint(x: first.x, y: size.height))
            for point in points { path.addLine(to: point) }
            path.addLine(to: CGPoint(x: last.x, y: size.height))
            path.closeSubpath()
        }
    }
}
