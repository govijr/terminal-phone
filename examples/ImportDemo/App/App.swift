import ActivityKit
import SwiftUI
import UIKit

@main
struct MisentoApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

let pink = Color(red: 1.0, green: 0.18, blue: 0.62)

@MainActor
final class Importer: ObservableObject {
    @Published var count = 0
    @Published var currentYear = 0
    @Published var running = false
    @Published var finished = false
    let years = Array((2019...2026).reversed())
    private var activity: Activity<ImportAttributes>?
    private var task: Task<Void, Never>?
    private var background: UIBackgroundTaskIdentifier = .invalid

    func start() {
        guard !running else { return }
        count = 48_215; currentYear = years[0]; finished = false; running = true
        // Keep counting for a while after the user goes Home, so the Dynamic Island keeps moving.
        background = UIApplication.shared.beginBackgroundTask { [weak self] in self?.endBackground() }
        let state = ImportAttributes.ContentState(count: count, currentYear: currentYear, finished: false)
        activity = try? Activity.request(attributes: ImportAttributes(years: years),
                                         content: .init(state: state, staleDate: nil))
        task = Task { await run() }
    }

    func stop() {
        task?.cancel(); task = nil; running = false
        Task { await activity?.end(nil, dismissalPolicy: .immediate); activity = nil }
        endBackground()
    }

    private func run() async {
        var tick = 0
        var alerted = false
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(900))
            if Task.isCancelled { return }
            tick += 1
            count += Int.random(in: 480...900)
            if tick % 3 == 0, let i = years.firstIndex(of: currentYear) {
                if i + 1 < years.count { currentYear = years[i + 1] } else { break }
            }
            let state = ImportAttributes.ContentState(count: count, currentYear: currentYear, finished: false)
            // The first update after going Home pops the expanded Dynamic Island, like the video.
            let alert: AlertConfiguration? = (!alerted && UIApplication.shared.applicationState != .active)
                ? AlertConfiguration(title: "Importing", body: "Your messages", sound: .default) : nil
            if alert != nil { alerted = true }
            await activity?.update(.init(state: state, staleDate: nil), alertConfiguration: alert)
        }
        finished = true; running = false
        let done = ImportAttributes.ContentState(count: count, currentYear: currentYear, finished: true)
        await activity?.end(.init(state: done, staleDate: nil), dismissalPolicy: .after(.now + 8))
        activity = nil
        endBackground()
    }

    private func endBackground() {
        if background != .invalid { UIApplication.shared.endBackgroundTask(background); background = .invalid }
    }
}

struct ContentView: View {
    @StateObject private var importer = Importer()

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.09, green: 0.07, blue: 0.16), .black],
                           startPoint: .top, endPoint: .bottom).ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer()
                Image(systemName: "bubble.left.fill")
                    .font(.system(size: 72)).foregroundStyle(pink)
                    .overlay(Image(systemName: "face.smiling").font(.system(size: 30, weight: .bold))
                        .foregroundStyle(.white).offset(y: -6))
                Text("Misento").font(.system(size: 40, weight: .bold)).foregroundStyle(.white)
                Text(importer.finished ? "Import complete" : importer.running ? "Importing your messages" : "Bring your message history over")
                    .foregroundStyle(.white.opacity(0.7)).accessibilityIdentifier("status")

                if importer.running || importer.finished {
                    VStack(spacing: 10) {
                        Text(ImportFormat.count(importer.count))
                            .font(.system(size: 56, weight: .bold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(.white).contentTransition(.numericText())
                            .accessibilityIdentifier("count")
                        YearsRow(years: importer.years, current: importer.currentYear, finished: importer.finished)
                            .accessibilityIdentifier("years")
                    }
                    .animation(.snappy, value: importer.count)
                }
                Spacer()
                Button(importer.running ? "Stop import" : "Import messages") {
                    importer.running ? importer.stop() : importer.start()
                }
                .font(.headline).foregroundStyle(.white)
                .frame(maxWidth: .infinity).padding(.vertical, 16)
                .background(importer.running ? Color.white.opacity(0.15) : pink, in: .capsule)
                .accessibilityIdentifier(importer.running ? "stop" : "import")
                .padding(.horizontal, 28)
                Text(importer.running ? "Go Home to watch it in the Dynamic Island" : " ")
                    .font(.footnote).foregroundStyle(.white.opacity(0.5))
            }
            .padding(.bottom, 24)
        }
    }
}

struct YearsRow: View {
    let years: [Int]; let current: Int; let finished: Bool
    var body: some View {
        HStack(spacing: 10) {
            ForEach(years, id: \.self) { year in
                let done = finished || year > current
                Text(done ? "✓\(String(year))" : String(year))
                    .font(.system(size: year == current && !finished ? 17 : 13, weight: .bold, design: .rounded))
                    .foregroundStyle(year == current && !finished ? pink : .white.opacity(done ? 0.9 : 0.35))
            }
        }
    }
}
