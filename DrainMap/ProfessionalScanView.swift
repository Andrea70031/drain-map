import SwiftUI
import UIKit

struct ProfessionalScanView: View {
    @EnvironmentObject private var store: ScanStore
    @StateObject private var scanner = LiDARScanner()
    @State private var analyzedMetrics: ScanMetrics?
    @State private var showAnalysis = false

    private var pointProgress: Double {
        min(Double(scanner.acquiredPointCount) / Double(scanner.minimumRequiredPoints), 1)
    }

    private var coverageProgress: Double {
        min(scanner.metrics.coverage / scanner.minimumRequiredCoverage, 1)
    }

    private var liveValuesReliable: Bool {
        scanner.metrics.hasMeasurement &&
        scanner.metrics.coverage >= 0.30 &&
        scanner.qualityAssessment.score >= 0.45
    }

    var body: some View {
        ZStack {
            if scanner.cameraDenied {
                cameraDeniedView
            } else if scanner.isSupported {
                ScannerCameraView(scanner: scanner, mode: .altimetry)
                    .ignoresSafeArea()
            } else {
                unsupportedView
            }

            LinearGradient(
                colors: [.black.opacity(0.46), .clear, .clear, .black.opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            if scanner.isSupported && !scanner.cameraDenied {
                VStack(spacing: 10) {
                    statusPill
                    if scanner.isMeasuring || scanner.latestSurface != nil {
                        altitudeLegend
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Spacer()
                    if scanner.isMeasuring {
                        liveReadout
                    }
                    controlPanel
                }
                .padding(.horizontal, 14)
                .padding(.top, 8)
                .padding(.bottom, 8)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { scanner.start() }
        .onDisappear {
            if !showAnalysis { scanner.pause() }
        }
        .fullScreenCover(isPresented: $showAnalysis) {
            if let analyzedMetrics {
                ProfessionalAnalysisView(
                    scanner: scanner,
                    metrics: analyzedMetrics,
                    onSave: {
                        store.add(ScanRecord(metrics: analyzedMetrics))
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

    private var statusPill: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(scanner.isMeasuring ? Color.cyan : scanner.latestSurface != nil ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
                .shadow(color: scanner.isMeasuring ? .cyan : .clear, radius: 6)
            Text(scanner.isMeasuring ? "Altimetria AR live" : scanner.latestSurface != nil ? "Rilievo pronto" : "Pronto alla scansione")
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

    private var altitudeLegend: some View {
        HStack(spacing: 9) {
            LinearGradient(
                colors: [.red, .orange, .yellow, .green, .cyan, .blue],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: 13, height: 112)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            VStack(alignment: .leading) {
                Text(liveValuesReliable ? scanner.metrics.maximumHeightLabel : "—")
                Spacer()
                Text("0 mm")
                Spacer()
                Text(liveValuesReliable ? scanner.metrics.minimumHeightLabel : "—")
            }
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
        }
        .padding(11)
        .frame(height: 138)
        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.12)))
    }

    private var liveReadout: some View {
        HStack(spacing: 7) {
            liveMetric("PENDENZA", liveValuesReliable ? String(format: "%.1f%%", scanner.metrics.slopePercent) : "—")
            liveMetric("MIN", liveValuesReliable ? scanner.metrics.minimumHeightLabel : "—")
            liveMetric("MAX", liveValuesReliable ? scanner.metrics.maximumHeightLabel : "—")
            liveMetric("Δ", liveValuesReliable ? scanner.metrics.reliefLabel : "—")
        }
    }

    private func liveMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.72))
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.white.opacity(0.09)))
    }

    private var controlPanel: some View {
        VStack(spacing: 10) {
            if scanner.isMeasuring {
                progressLine(
                    title: "PUNTI LiDAR",
                    value: "\(scanner.acquiredPointCount.formatted()) / \(scanner.minimumRequiredPoints.formatted())",
                    progress: pointProgress,
                    ready: scanner.acquiredPointCount >= scanner.minimumRequiredPoints
                )
                progressLine(
                    title: "COPERTURA",
                    value: "\(scanner.metrics.coverageLabel) / \(Int(scanner.minimumRequiredCoverage * 100))%",
                    progress: coverageProgress,
                    ready: scanner.metrics.coverage >= scanner.minimumRequiredCoverage
                )

                HStack {
                    Text("QUALITÀ")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.7)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(scanner.qualityAssessment.label)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(scanner.qualityAssessment.isSufficient ? .green : .orange)
                }

                HStack(spacing: 10) {
                    Button { scanner.cancelMeasurement() } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .frame(width: 52, height: 52)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))

                    Button(action: finishScan) {
                        Label(finalizeTitle, systemImage: scanner.canFinalize ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right")
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(scanner.canFinalize ? .black : .white.opacity(0.58))
                    .background(scanner.canFinalize ? Color.cyan : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    .disabled(!scanner.canFinalize)
                }

                Text(scanner.qualityAssessment.warning ?? "Rilievo valido: puoi concludere o continuare per aumentare la stabilità.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if analyzedMetrics != nil {
                HStack(spacing: 10) {
                    Button(action: startScan) {
                        Label("Nuovo", systemImage: "arrow.counterclockwise")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))

                    Button { showAnalysis = true } label: {
                        Label("Analizza", systemImage: "drop.fill")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.black)
                    .background(Color.cyan, in: RoundedRectangle(cornerRadius: 15))
                }
            } else {
                Button(action: startScan) {
                    Label("Avvia scansione LiDAR", systemImage: "viewfinder")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black)
                .background(scanner.isRunning ? Color.cyan : Color.gray, in: RoundedRectangle(cornerRadius: 17))
                .disabled(!scanner.isRunning)

                Text("La superficie verrà colorata direttamente in AR. Minimo 15.000 punti e 60% di copertura.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.12)))
    }

    private var finalizeTitle: String {
        if scanner.acquiredPointCount < scanner.minimumRequiredPoints {
            return "Ancora \(max(scanner.minimumRequiredPoints - scanner.acquiredPointCount, 0).formatted()) punti"
        }
        if scanner.metrics.coverage < scanner.minimumRequiredCoverage { return "Aumenta copertura" }
        if !scanner.qualityAssessment.isSufficient { return "Migliora qualità" }
        return "Concludi rilievo"
    }

    private func progressLine(title: String, value: String, progress: Double, ready: Bool) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.7)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(value)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(ready ? .green : .cyan)
            }
            ProgressView(value: progress)
                .tint(ready ? .green : .cyan)
        }
    }

    private func startScan() {
        analyzedMetrics = nil
        scanner.beginMeasurement()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func finishScan() {
        guard scanner.canFinalize, let result = scanner.finishMeasurement() else { return }
        analyzedMetrics = result
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showAnalysis = true
    }

    private var unsupportedView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "sensor.tag.radiowaves.forward")
                    .font(.system(size: 52, weight: .thin))
                    .foregroundStyle(.cyan)
                Text("LiDAR non disponibile").font(.title2.weight(.semibold))
                Text("DrainMap richiede un iPhone con LiDAR e supporto sceneDepth.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 30)
            }
        }
    }

    private var cameraDeniedView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(.cyan)
                Text("Accesso alla fotocamera").font(.title2.weight(.semibold))
                Text("Abilita la fotocamera per utilizzare rilievo LiDAR e overlay AR.")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Button("Apri Impostazioni") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .foregroundStyle(.black)
            }
            .padding(24)
        }
    }
}
