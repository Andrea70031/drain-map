import SwiftUI
import UIKit

struct RootView: View {
    var body: some View {
        TabView {
            LiveDrainScanView()
                .tabItem { Label("Scansione", systemImage: "viewfinder") }

            SettingsView()
                .tabItem { Label("Manuale", systemImage: "book.closed") }

            HistoryView()
                .tabItem { Label("Libreria", systemImage: "square.stack.3d.up") }
        }
        .tint(.cyan)
    }
}

struct LiveDrainScanView: View {
    @EnvironmentObject private var store: ScanStore
    @StateObject private var scanner = LiDARScanner()
    @State private var analyzedMetrics: ScanMetrics?
    @State private var showAnalysis = false

    private var pointReady: Bool {
        scanner.acquiredPointCount >= scanner.minimumRequiredPoints
    }

    private var coverageReady: Bool {
        scanner.metrics.coverage >= scanner.minimumRequiredCoverage
    }

    private var canAnalyze: Bool {
        scanner.metrics.hasMeasurement && pointReady && coverageReady
    }

    var body: some View {
        ZStack {
            if scanner.cameraDenied {
                cameraDeniedView
            } else if scanner.isSupported {
                ScannerCameraView(scanner: scanner)
                    .ignoresSafeArea()
            } else {
                unsupportedView
            }

            LinearGradient(
                colors: [.black.opacity(0.48), .clear, .clear, .black.opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            if !scanner.cameraDenied, scanner.isSupported {
                VStack(spacing: 10) {
                    statusBar
                    if scanner.isMeasuring { liveLegend }
                    Spacer()
                    scanFrame
                    Spacer()
                    controlPanel
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { scanner.start() }
        .fullScreenCover(isPresented: $showAnalysis) {
            if let analyzedMetrics {
                DrainMapAnalysisStudio(
                    metrics: analyzedMetrics,
                    measuredAt: .now,
                    onSave: {
                        store.add(ScanRecord(metrics: analyzedMetrics))
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    },
                    onNewScan: {
                        showAnalysis = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            startScan()
                        }
                    }
                )
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(scanner.isMeasuring ? Color.cyan : Color.orange)
                .frame(width: 8, height: 8)
                .shadow(color: .cyan, radius: scanner.isMeasuring ? 6 : 0)
            Text(scanner.isMeasuring ? "Deflusso LiDAR live" : "Pronto alla scansione")
                .font(.caption.weight(.semibold))
            Spacer()
            if scanner.isMeasuring {
                Text("\(scanner.acquiredPointCount.formatted()) pt")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.cyan)
            }
            Text("DRAINMAP")
                .font(.caption2.weight(.bold))
                .tracking(1.8)
                .foregroundStyle(.cyan)
        }
        .padding(.horizontal, 13)
        .frame(height: 42)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12)))
    }

    private var liveLegend: some View {
        VStack(spacing: 7) {
            HStack {
                Label("FLUSSI COLORATI IN TEMPO REALE", systemImage: "drop.fill")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.6)
                Spacer()
                if !scanner.liveFlowPools.isEmpty {
                    Label("RISTAGNO", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.red)
                }
            }
            HStack(spacing: 5) {
                Circle().fill(.blue).frame(width: 8, height: 8)
                Circle().fill(.cyan).frame(width: 8, height: 8)
                Circle().fill(.green).frame(width: 8, height: 8)
                Circle().fill(.yellow).frame(width: 8, height: 8)
                Circle().fill(.orange).frame(width: 8, height: 8)
                Text("lento → veloce")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Circle().fill(.red).frame(width: 8, height: 8)
                Text("ristagno")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private var scanFrame: some View {
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .stroke(scanner.isMeasuring ? Color.cyan.opacity(0.75) : Color.white.opacity(0.55), lineWidth: 2)
            .frame(height: 330)
            .overlay(alignment: .bottomLeading) {
                Text(scanner.isMeasuring ? "Muovi lentamente: le scie trasparenti seguono il deflusso sulla superficie" : "Inquadra pavimento o terrazza")
                    .font(.caption2.weight(.medium))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(.black.opacity(0.52), in: Capsule())
                    .padding(10)
            }
            .allowsHitTesting(false)
    }

    private var controlPanel: some View {
        VStack(spacing: 10) {
            if scanner.isMeasuring {
                progressLine(
                    title: "PUNTI LiDAR",
                    value: "\(scanner.acquiredPointCount.formatted()) / \(scanner.minimumRequiredPoints.formatted())",
                    progress: min(Double(scanner.acquiredPointCount) / Double(scanner.minimumRequiredPoints), 1),
                    ready: pointReady
                )
                progressLine(
                    title: "COPERTURA",
                    value: "\(scanner.metrics.coverageLabel) / \(Int(scanner.minimumRequiredCoverage * 100))%",
                    progress: min(scanner.metrics.coverage / scanner.minimumRequiredCoverage, 1),
                    ready: coverageReady
                )

                HStack(spacing: 8) {
                    metric("PENDENZA", scanner.metrics.hasMeasurement ? String(format: "%.1f%%", scanner.metrics.slopePercent) : "—")
                    metric("DISTANZA", scanner.metrics.hasMeasurement ? String(format: "%.2f m", scanner.metrics.distanceMeters) : "—")
                    metric("QUALITÀ", scanner.metrics.hasMeasurement ? scanner.metrics.qualityLabel : "—")
                }

                HStack(spacing: 10) {
                    Button(action: cancelScan) {
                        Image(systemName: "xmark")
                            .frame(width: 52, height: 52)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))

                    Button(action: finishScan) {
                        Label(buttonTitle, systemImage: canAnalyze ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right")
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canAnalyze ? .black : .white.opacity(0.58))
                    .background(canAnalyze ? Color.cyan : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
                    .disabled(!canAnalyze)
                }
            } else if analyzedMetrics != nil {
                HStack(spacing: 10) {
                    Button("Nuovo rilievo", action: startScan)
                        .buttonStyle(.bordered)
                    Button("Apri analisi") { showAnalysis = true }
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                        .foregroundStyle(.black)
                }
            } else {
                Button(action: startScan) {
                    Label("Avvia scansione LiDAR", systemImage: "viewfinder")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black)
                .background(Color.cyan, in: RoundedRectangle(cornerRadius: 16))
                Text("Analisi bloccata sotto 15.000 punti e 60% di copertura")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.12)))
    }

    private var buttonTitle: String {
        if !pointReady {
            return "Ancora \(max(scanner.minimumRequiredPoints - scanner.acquiredPointCount, 0).formatted()) punti"
        }
        if !coverageReady { return "Aumenta copertura" }
        return "Analizza superficie"
    }

    private func progressLine(title: String, value: String, progress: Double, ready: Bool) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(title).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
                Spacer()
                if ready { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                Text(value).font(.caption2.weight(.semibold)).monospacedDigit().foregroundStyle(ready ? .green : .cyan)
            }
            ProgressView(value: progress).tint(ready ? .green : .cyan)
        }
    }

    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            Text(value).font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 11))
    }

    private func startScan() {
        analyzedMetrics = nil
        if scanner.isRunning {
            scanner.beginMeasurement()
        } else {
            scanner.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                scanner.beginMeasurement()
            }
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func cancelScan() {
        scanner.cancelMeasurement()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func finishScan() {
        guard canAnalyze, let result = scanner.finishMeasurement() else { return }
        analyzedMetrics = result
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showAnalysis = true
    }

    private var unsupportedView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Text("DrainMap richiede un iPhone con LiDAR").foregroundStyle(.white)
        }
    }

    private var cameraDeniedView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "camera.fill").font(.largeTitle).foregroundStyle(.cyan)
                Text("Abilita la fotocamera per usare LiDAR e deflusso live")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                Button("Apri Impostazioni") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            .padding(24)
        }
    }
}
