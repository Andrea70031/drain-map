import SwiftUI
import UIKit

struct LiveDrainScanView: View {
    @EnvironmentObject private var store: ScanStore
    @StateObject private var scanner = LiDARScanner()
    @AppStorage("didCompleteOnboarding") private var didCompleteOnboarding = false

    @State private var showOnboarding = false
    @State private var analyzedMetrics: ScanMetrics?
    @State private var showAnalysisStudio = false

    private var pointProgress: Double {
        min(Double(scanner.acquiredPointCount) / Double(scanner.minimumRequiredPoints), 1)
    }

    private var coverageProgress: Double {
        min(scanner.metrics.coverage / scanner.minimumRequiredCoverage, 1)
    }

    private var hasEnoughPoints: Bool {
        scanner.acquiredPointCount >= scanner.minimumRequiredPoints
    }

    private var hasEnoughCoverage: Bool {
        scanner.metrics.coverage >= scanner.minimumRequiredCoverage
    }

    private var canAnalyze: Bool {
        scanner.metrics.hasMeasurement && hasEnoughPoints && hasEnoughCoverage
    }

    var body: some View {
        ZStack {
            if scanner.cameraDenied {
                cameraDeniedBackground
            } else if scanner.isSupported {
                ScannerCameraView(scanner: scanner)
                    .ignoresSafeArea()
            } else {
                unsupportedBackground
            }

            LinearGradient(
                colors: [.black.opacity(0.48), .clear, .clear, .black.opacity(0.86)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            if !scanner.cameraDenied, scanner.isSupported {
                VStack(spacing: 10) {
                    topBar
                        .padding(.top, 7)

                    if scanner.isMeasuring {
                        liveLegend
                    } else {
                        guidanceCard
                    }

                    Spacer(minLength: 8)

                    scanFrame

                    Spacer(minLength: 10)

                    controlPanel
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if didCompleteOnboarding {
                scanner.start()
            } else {
                showOnboarding = true
            }
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            LiveScanOnboardingView {
                didCompleteOnboarding = true
                showOnboarding = false
                scanner.start()
            }
            .interactiveDismissDisabled()
        }
        .fullScreenCover(isPresented: $showAnalysisStudio) {
            if let analyzedMetrics {
                DrainMapAnalysisStudio(
                    metrics: analyzedMetrics,
                    measuredAt: .now,
                    onSave: {
                        store.add(ScanRecord(metrics: analyzedMetrics))
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    },
                    onNewScan: {
                        showAnalysisStudio = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            if scanner.isRunning {
                                startMeasurement()
                            } else {
                                scanner.start()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                                    startMeasurement()
                                }
                            }
                        }
                    }
                )
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor, radius: 7)

            Text(statusText)
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
                .tracking(2.0)
                .foregroundStyle(.cyan)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private var statusText: String {
        if scanner.isMeasuring { return "Deflusso LiDAR live" }
        if analyzedMetrics != nil { return "Ultimo rilievo pronto" }
        if scanner.isRunning { return "Pronto alla scansione" }
        return "Avvio LiDAR…"
    }

    private var statusColor: Color {
        if scanner.isMeasuring { return .cyan }
        if analyzedMetrics != nil { return .green }
        return .orange
    }

    private var liveLegend: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Label("DEFLUSSO IN TEMPO REALE", systemImage: "drop.fill")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(0.7)
                Spacer()
                if !scanner.liveFlowPools.isEmpty {
                    Label("RISTAGNO", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.red)
                }
            }

            HStack(spacing: 5) {
                legendDot(.blue, "lento")
                legendDot(.cyan, nil)
                legendDot(.green, nil)
                legendDot(.yellow, nil)
                legendDot(.orange, "veloce")
                Spacer()
                HStack(spacing: 4) {
                    Circle().fill(.red.opacity(0.85)).frame(width: 7, height: 7)
                    Text("rosso = possibile ristagno")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(.white.opacity(0.10), lineWidth: 1))
    }

    private func legendDot(_ color: Color, _ label: String?) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 8, height: 8)
            if let label {
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var guidanceCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(.cyan.opacity(0.13)).frame(width: 42, height: 42)
                Image(systemName: "viewfinder")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.cyan)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Inquadra pavimento o terrazza")
                    .font(.subheadline.weight(.semibold))
                Text("Durante il rilievo vedrai direttamente sulla fotocamera le scie colorate e trasparenti del deflusso.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.09), lineWidth: 1))
    }

    private var scanFrame: some View {
        GeometryReader { _ in
            ZStack {
                LiveScanCorners()
                    .stroke(
                        scanner.isMeasuring ? Color.cyan.opacity(0.78) : Color.white.opacity(0.70),
                        style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                    )
                    .shadow(color: scanner.isMeasuring ? .cyan.opacity(0.50) : .clear, radius: 8)

                if scanner.isMeasuring {
                    VStack {
                        HStack {
                            Text("AREA LiDAR")
                                .font(.system(size: 9, weight: .bold))
                                .tracking(1)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(.black.opacity(0.52), in: Capsule())
                            Spacer()
                        }
                        Spacer()
                        HStack {
                            Text("Le scie seguono la superficie letta in questo momento")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.white.opacity(0.90))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(.black.opacity(0.48), in: Capsule())
                            Spacer()
                        }
                    }
                    .padding(10)
                } else {
                    VStack {
                        Spacer()
                        Label("Mantieni la superficie dentro l’area", systemImage: "scope")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 11)
                            .padding(.vertical, 7)
                            .background(.black.opacity(0.48), in: Capsule())
                            .padding(.bottom, 10)
                    }
                }
            }
        }
        .frame(height: 335)
        .padding(.horizontal, 3)
    }

    private var controlPanel: some View {
        VStack(spacing: 11) {
            if scanner.isMeasuring {
                progressRow(
                    title: "PUNTI LiDAR",
                    value: "\(scanner.acquiredPointCount.formatted()) / \(scanner.minimumRequiredPoints.formatted())",
                    progress: pointProgress,
                    ready: hasEnoughPoints
                )

                progressRow(
                    title: "COPERTURA SUPERFICIE",
                    value: "\(scanner.metrics.coverageLabel) / \(Int(scanner.minimumRequiredCoverage * 100))%",
                    progress: coverageProgress,
                    ready: hasEnoughCoverage
                )

                HStack(spacing: 8) {
                    metricChip(
                        title: "PENDENZA LIVE",
                        value: scanner.metrics.hasMeasurement ? String(format: "%.1f %%", scanner.metrics.slopePercent) : "—"
                    )
                    metricChip(
                        title: "DISTANZA",
                        value: scanner.metrics.hasMeasurement ? String(format: "%.2f m", scanner.metrics.distanceMeters) : "—"
                    )
                    metricChip(
                        title: "QUALITÀ",
                        value: scanner.metrics.hasMeasurement ? scanner.metrics.qualityLabel : "—"
                    )
                }

                HStack(spacing: 10) {
                    Button(action: cancelMeasurement) {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .frame(width: 52, height: 52)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    Button(action: completeAnalysis) {
                        HStack(spacing: 8) {
                            Image(systemName: canAnalyze ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right")
                            Text(analysisButtonTitle)
                                .fontWeight(.semibold)
                                .lineLimit(1)
                                .minimumScaleFactor(0.76)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canAnalyze ? .black : .white.opacity(0.62))
                    .background(canAnalyze ? Color.cyan : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .disabled(!canAnalyze)
                }

                Text(scanHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if analyzedMetrics != nil {
                HStack(spacing: 10) {
                    Button(action: startMeasurement) {
                        Label("Nuovo", systemImage: "arrow.counterclockwise")
                            .fontWeight(.semibold)
                            .frame(width: 104, height: 52)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    Button {
                        showAnalysisStudio = true
                    } label: {
                        Label("Apri analisi", systemImage: "square.grid.2x2.fill")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.black)
                    .background(Color.cyan, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            } else {
                Button(action: startMeasurement) {
                    HStack(spacing: 10) {
                        Image(systemName: "viewfinder")
                        Text("Avvia scansione LiDAR")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black)
                .background(scanner.isRunning ? Color.cyan : Color.gray, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .disabled(!scanner.isRunning)

                Text("Minimo 15.000 punti · copertura minima 60% · deflusso visualizzato live")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 23, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 23, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private var analysisButtonTitle: String {
        if !hasEnoughPoints {
            let missing = max(scanner.minimumRequiredPoints - scanner.acquiredPointCount, 0)
            return "Ancora \(missing.formatted()) punti"
        }
        if !hasEnoughCoverage {
            return "Aumenta copertura"
        }
        return "Analizza superficie"
    }

    private var scanHint: String {
        if !hasEnoughPoints {
            return "Muovi lentamente l’iPhone: l’analisi si sblocca solo dopo almeno 15.000 punti LiDAR reali."
        }
        if !hasEnoughCoverage {
            return "Punti sufficienti. Ora passa sulle zone ancora non coperte finché raggiungi almeno il 60%."
        }
        return "Rilievo denso e copertura sufficienti. Puoi analizzare oppure continuare per aumentare la precisione."
    }

    private func progressRow(title: String, value: String, progress: Double, ready: Bool) -> some View {
        VStack(spacing: 6) {
            HStack {
                Text(title)
                    .font(.system(size: 9, weight: .bold))
                    .tracking(1)
                    .foregroundStyle(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    if ready {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    Text(value)
                        .font(.caption2.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(ready ? .green : .cyan)
                }
            }
            ProgressView(value: progress)
                .tint(ready ? .green : .cyan)
        }
    }

    private func metricChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 8, weight: .bold))
                .tracking(0.55)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.70)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }

    private func startMeasurement() {
        analyzedMetrics = nil
        scanner.beginMeasurement()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func cancelMeasurement() {
        scanner.cancelMeasurement()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func completeAnalysis() {
        guard canAnalyze, let finalMetrics = scanner.finishMeasurement() else { return }
        analyzedMetrics = finalMetrics
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showAnalysisStudio = true
    }

    private var unsupportedBackground: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "sensor.tag.radiowaves.forward")
                    .font(.system(size: 52, weight: .thin))
                    .foregroundStyle(.cyan)
                Text("LiDAR non disponibile")
                    .font(.title2.weight(.semibold))
                Text("DrainMap richiede un iPhone dotato di sensore LiDAR per costruire la superficie e visualizzare il deflusso live.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 28)
            }
        }
    }

    private var cameraDeniedBackground: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 16) {
                ZStack {
                    Circle().fill(.cyan.opacity(0.10)).frame(width: 92, height: 92)
                    Image(systemName: "camera.fill")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.cyan)
                }
                Text("Accesso alla fotocamera")
                    .font(.title2.weight(.semibold))
                Text("DrainMap usa fotocamera e LiDAR per mostrare i deflussi direttamente sulla superficie.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 30)
                Button("Apri Impostazioni") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .foregroundStyle(.black)
            }
        }
    }
}

private struct LiveScanCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let length = min(rect.width, rect.height) * 0.15
        var path = Path()

        path.move(to: CGPoint(x: rect.minX, y: rect.minY + length))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + length, y: rect.minY))

        path.move(to: CGPoint(x: rect.maxX - length, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + length))

        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - length))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - length, y: rect.maxY))

        path.move(to: CGPoint(x: rect.minX + length, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - length))
        return path
    }
}

private struct LiveScanOnboardingView: View {
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.0, green: 0.08, blue: 0.10)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                ZStack {
                    Circle().fill(.cyan.opacity(0.10)).frame(width: 116, height: 116)
                    Circle().stroke(.cyan.opacity(0.30), lineWidth: 1).frame(width: 116, height: 116)
                    Image(systemName: "water.waves")
                        .font(.system(size: 46, weight: .thin))
                        .foregroundStyle(.cyan)
                }

                VStack(spacing: 8) {
                    Text("DrainMap Live")
                        .font(.largeTitle.weight(.bold))
                    Text("Scansiona la superficie e guarda il deflusso direttamente sulla fotocamera.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 26)
                }

                VStack(spacing: 12) {
                    onboardingRow("15.000+ punti", "L’analisi resta bloccata finché il rilievo non è abbastanza denso.", "dot.radiowaves.left.and.right")
                    onboardingRow("Deflusso colorato live", "Le scie trasparenti mostrano direzione e intensità mentre scansioni.", "drop.fill")
                    onboardingRow("Ristagni evidenziati", "Le zone rosse indicano possibili minimi locali da verificare.", "exclamationmark.triangle.fill")
                }
                .padding(.horizontal, 20)

                Spacer()

                Button(action: onContinue) {
                    Text("Inizia")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .frame(height: 56)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black)
                .background(Color.cyan, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func onboardingRow(_ title: String, _ subtitle: String, _ icon: String) -> some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(.cyan.opacity(0.10))
                    .frame(width: 46, height: 46)
                Image(systemName: icon)
                    .foregroundStyle(.cyan)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(11)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}