import ActivityKit
import SwiftUI
import WidgetKit

@main
struct MisentoWidgets: WidgetBundle {
    var body: some Widget { ImportLiveActivity() }
}

private let pink = Color(red: 1.0, green: 0.18, blue: 0.62)

private struct Logo: View {
    var size: CGFloat
    var body: some View {
        Image(systemName: "bubble.left.fill").font(.system(size: size)).foregroundStyle(pink)
            .overlay(Image(systemName: "face.smiling").font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(.white).offset(y: -size * 0.08))
    }
}

/// "2026 ✓2025 ✓2024 ... 2021": checked years white, the current one pink, kept at the trailing edge.
private struct YearsTicker: View {
    let years: [Int]; let state: ImportAttributes.ContentState
    var body: some View {
        HStack(spacing: 8) {
            ForEach(years.filter { $0 >= state.currentYear }, id: \.self) { year in
                let current = year == state.currentYear && !state.finished
                Text(current ? String(year) : "✓\(String(year))")
                    .font(.system(size: current ? 17 : 12, weight: .bold, design: .rounded))
                    .foregroundStyle(current ? pink : .white)
            }
        }
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .trailing)
        .clipped()
    }
}

struct ImportLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ImportAttributes.self) { context in
            // Lock Screen / banner
            VStack(spacing: 10) {
                HStack {
                    Logo(size: 26)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(context.state.finished ? "Imported" : "Importing").font(.subheadline.bold())
                        Text("Your messages").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(ImportFormat.count(context.state.count))
                        .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                }
                YearsTicker(years: context.attributes.years, state: context.state)
            }
            .padding(16)
            .foregroundStyle(.white)
            .activityBackgroundTint(.black)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Logo(size: 22)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(context.state.finished ? "Imported" : "Importing").font(.caption.bold())
                            Text("Your messages").font(.caption2).foregroundStyle(.secondary)
                        }
                        .fixedSize()
                    }
                    .padding(.leading, 4).frame(maxHeight: .infinity)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(ImportFormat.count(context.state.count))
                        .font(.system(size: 30, weight: .bold, design: .rounded)).monospacedDigit()
                        .contentTransition(.numericText())
                        .fixedSize().padding(.trailing, 4).frame(maxHeight: .infinity)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    YearsTicker(years: context.attributes.years, state: context.state).padding(.horizontal, 4)
                }
            } compactLeading: {
                Logo(size: 15)
            } compactTrailing: {
                Text(context.state.finished ? "✓" : String(context.state.currentYear))
                    .font(.system(size: 14, weight: .bold, design: .rounded)).foregroundStyle(pink)
            } minimal: {
                Logo(size: 14)
            }
            .keylineTint(pink)
        }
    }
}
