import SwiftUI
import UIKit

struct ScanView: View {
    @EnvironmentObject private var store: ScanStore
    @StateObject private var scanner = LiDARScanner()
    @AppStorage("didCompleteOnboarding") private var didCompleteOnboarding = false

    @State private var showOnboarding = false
    @State private var analyzedMetrics: ScanMetrics?
    @State private var showAnalysisStudio = false

    private var canAnalyze: Bool {
        scanner.metrics.hasMeasurement && scanner.metrics.coverage >= 0.32 && scanner.metrics.sampleCount >= 180
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
                colors: [.black.opacity(0.48), .clear, .black.opacity(0.86)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            if !scanner.cameraDenied, scanner.isSupported {
                VStack(spacing: 12) {
                    statusBar
                        .padding(.top, 8)

                    guidanceCard

                    Spacer(minLength: 6)

                    scanFrame

                    Spacer(minLength: 8)

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
        .onDisappear { scanner.pause() }
        .fullScreenCover(isPresented: $showOnboarding) {
            DrainMapOnboardingView {
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
                            startMeasurement()
                        }
                    }
                )
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .shadow(color: statusColor, radius: 7)

            Text(statusText)
                .font(.caption.weight(.semibold))

            Spacer()

            if scanner.supportsMeshReconstruction {
                Label("MESH", systemImage: "cube.transparent")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.cyan)
            }

            Text("DRAINMAP")
                .font(.caption2.weight(.bold))
                .tracking(2.1)
                .foregroundStyle(.cyan)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private var statusText: String {
        if scanner.isMeasuring { return "Scansione LiDAR in corso" }
        if analyzedMetrics != nil { return "Ultimo rilievo pronto" }
        if scanner.isRunning { return "Pronto alla scansione" }
        return "Avvio LiDAR…"
    }

    private var statusColor: Color {
        if scanner.isMeasuring { return .cyan }
        if analyzedMetrics != nil { return .green }
        return .orange
    }

    private var guidanceCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(.cyan.opacity(0.13))
                    .frame(width: 42, height: 42)
                Image(systemName: scanner.isMeasuring ? "move.3d" : "viewfinder")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.cyan)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(scanner.isMeasuring ? "Muovi lentamente sull’intera superficie" : "Inquadra la superficie da analizzare")
                    .font(.subheadline.weight(.semibold))
                Text(scanner.isMeasuring
                     ? "La rete azzurra è la mesh 3D ricostruita dal LiDAR. Copri bene pavimento o terrazza prima di analizzare."
                     : "Tieni l’iPhone inclinato verso il pavimento. Premi Avvia scansione quando la zona è ben visibile.")
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
        GeometryReader { geometry in
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .fill(.clear)

                ScanCorners()
                    .stroke(scanner.isMeasuring ? Color.cyan : Color.white.opacity(0.85), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    .shadow(color: scanner.isMeasuring ? .cyan.opacity(0.65) : .clear, radius: 8)
                    .padding(2)

                if scanner.isMeasuring {
                    VStack {
                        HStack {
                            Label("SUPERFICIE IN ACQUISIZIONE", systemImage: "dot.radiowaves.left.and.right")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(0.7)
                                .foregroundStyle(.white)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(.black.opacity(0.62), in: Capsule())
                            Spacer()
                            Text(scanner.metrics.hasMeasurement ? scanner.metrics.coverageLabel : "0%")
                                .font(.caption.weight(.bold))
                                .monospacedDigit()
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(.black.opacity(0.62), in: Capsule())
                        }

                        Spacer()

                        HStack {
                            Label(
                                scanner.metrics.meshAnchorCount > 0 ? "Mesh 3D rilevata" : "Cerca la superficie",
                                systemImage: scanner.metrics.meshAnchorCount > 0 ? "cube.transparent.fill" : "scope"
                            )
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.white.opacity(0.94))
                            Spacer()
                            if scanner.metrics.hasMeasurement {
                                Text("\(scanner.metrics.sampleCount) punti")
                                    .font(.caption2.weight(.semibold))
                                    .monospacedDigit()
                            }
                        }
                        .padding(10)
                        .background(.black.opacity(0.46), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                    }
                    .padding(12)
                } else {
                    VStack {
                        Spacer()
                        Label("Porta qui la zona da scansionare", systemImage: "scope")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.black.opacity(0.52), in: Capsule())
                            .padding(.bottom, 12)
                    }
                }
            }
        }
        .frame(height: 330)
        .padding(.horizontal, 4)
    }

    private var controlPanel: some View {
        VStack(spacing: 12) {
            if scanner.isMeasuring {
                VStack(spacing: 9) {
                    HStack {
                        Text("COPERTURA SCANSIONE")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(scanner.metrics.hasMeasurement ? scanner.metrics.coverageLabel : "Acquisizione…")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.cyan)
                    }

                    ProgressView(value: scanner.metrics.hasMeasurement ? scanner.metrics.coverage : 0)
                        .tint(.cyan)

                    HStack(spacing: 8) {
                        metricChip(
                            title: "DISTANZA",
                            value: scanner.metrics.hasMeasurement ? String(format: "%.2f m", scanner.metrics.distanceMeters) : "—"
                        )
                        metricChip(
                            title: "PENDENZA LIVE",
                            value: scanner.metrics.hasMeasurement ? String(format: "%.1f %%", scanner.metrics.slopePercent) : "—"
                        )
                        metricChip(
                            title: "QUALITÀ",
                            value: scanner.metrics.hasMeasurement ? scanner.metrics.qualityLabel : "—"
                        )
                    }
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
                        HStack(spacing: 9) {
                            Image(systemName: "chart.xyaxis.line")
                            Text(canAnalyze ? "Analizza superficie" : "Continua la scansione")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canAnalyze ? .black : .white.opacity(0.55))
                    .background(canAnalyze ? Color.cyan : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .disabled(!canAnalyze)
                }

                Text(canAnalyze
                     ? "Copertura sufficiente. Puoi analizzare oppure continuare per migliorare il modello."
                     : "Passa lentamente su tutta la zona finché la copertura aumenta.")
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
                        Text("Avvia scansione")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black)
                .background(scanner.isRunning ? Color.cyan : Color.gray, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .disabled(!scanner.isRunning)

                Text("Scansiona → analizza pendenze → simula deflusso → esporta report")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(15)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private func metricChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.7)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
                Text("DrainMap richiede un iPhone dotato di sensore LiDAR per costruire la superficie 3D.")
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
                Text("DrainMap usa fotocamera e LiDAR per ricostruire la superficie. Abilita la fotocamera nelle Impostazioni per iniziare.")
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

private struct ScanCorners: Shape {
    func path(in rect: CGRect) -> Path {
        let length = min(rect.width, rect.height) * 0.16
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

struct DrainMapAnalysisStudio: View {
    enum Section: String, CaseIterable, Identifiable {
        case slopes = "Pendenze"
        case water = "Deflusso"
        case issues = "Problemi"
        case detail = "Dettaglio"
        case profile = "Profilo"
        case report = "Report"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .slopes: return "square.grid.3x3.fill"
            case .water: return "drop.fill"
            case .issues: return "exclamationmark.triangle.fill"
            case .detail: return "scope"
            case .profile: return "chart.xyaxis.line"
            case .report: return "doc.text.fill"
            }
        }
    }

    let metrics: ScanMetrics
    let measuredAt: Date
    var onSave: (() -> Void)? = nil
    var onNewScan: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @State private var section: Section = .slopes
    @State private var selectedIndex: Int?
    @State private var rainIntensity = 0.55
    @State private var saved = false
    @State private var reportURL: URL?
    @State private var showShareSheet = false

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color.black, Color(red: 0.01, green: 0.06, blue: 0.08)],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .ignoresSafeArea()

                VStack(spacing: 0) {
                    summaryHeader
                    sectionPicker

                    ScrollView {
                        Group {
                            switch section {
                            case .slopes: slopesSection
                            case .water: waterSection
                            case .issues: issuesSection
                            case .detail: detailSection
                            case .profile: profileSection
                            case .report: reportSection
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                }
            }
            .navigationTitle("Analisi superficie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                if let onSave {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            guard !saved else { return }
                            onSave()
                            saved = true
                        } label: {
                            Label(saved ? "Salvato" : "Salva", systemImage: saved ? "checkmark" : "square.and.arrow.down")
                        }
                        .disabled(saved)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showShareSheet) {
            if let reportURL {
                ActivityShareSheet(items: [reportURL])
            }
        }
        .onAppear {
            if selectedIndex == nil {
                selectedIndex = lowPointIndex
            }
        }
    }

    private var lowPointIndex: Int? {
        guard metrics.gridColumns > 0, metrics.gridRows > 0 else { return nil }
        let column = Int(round(metrics.lowPointX * Double(metrics.gridColumns - 1)))
        let row = Int(round(metrics.lowPointY * Double(metrics.gridRows - 1)))
        let index = row * metrics.gridColumns + column
        return metrics.surfaceGrid.indices.contains(index) ? index : nil
    }

    private var summaryHeader: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PENDENZA MEDIA")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1.3)
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(String(format: "%.1f", metrics.slopePercent))
                            .font(.system(size: 40, weight: .light, design: .rounded))
                            .monospacedDigit()
                        Text("%")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(.cyan)
                    }
                    Text(String(format: "%.2f°", metrics.slopeDegrees))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                directionCompass
            }

            HStack(spacing: 8) {
                summaryMetric("MIN", metrics.minimumHeightLabel)
                summaryMetric("MAX", metrics.maximumHeightLabel)
                summaryMetric("DISLIVELLO", metrics.reliefLabel)
                summaryMetric("COPERTURA", metrics.coverageLabel)
            }
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) { Divider().opacity(0.25) }
    }

    private var directionCompass: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().fill(.cyan.opacity(0.09)).frame(width: 62, height: 62)
                Circle().stroke(.cyan.opacity(0.25), lineWidth: 1).frame(width: 62, height: 62)
                Image(systemName: "arrow.up")
                    .font(.system(size: 27, weight: .light))
                    .foregroundStyle(.cyan)
                    .rotationEffect(.radians(metrics.downhillAngleRadians))
            }
            Text("DISCESA")
                .font(.system(size: 8, weight: .bold))
                .tracking(1)
                .foregroundStyle(.secondary)
        }
    }

    private func summaryMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var sectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Section.allCases) { item in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { section = item }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: item.icon)
                            Text(item.rawValue)
                        }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(section == item ? .black : .white)
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(section == item ? Color.cyan : Color.white.opacity(0.07), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(.black.opacity(0.32))
    }

    private var slopesSection: some View {
        VStack(spacing: 14) {
            sectionTitle("Mappa delle pendenze", "Altimetria relativa della superficie rilevata dal LiDAR.")

            SurfaceHeatmap(metrics: metrics, mode: .altitude, selectedIndex: .constant(nil))
                .frame(height: 330)

            HStack(spacing: 10) {
                infoCard(title: "Punto più basso", value: metrics.minimumHeightLabel, icon: "arrow.down.to.line.compact")
                infoCard(title: "Punto più alto", value: metrics.maximumHeightLabel, icon: "arrow.up.to.line.compact")
            }

            Text("La scala colori rappresenta la quota relativa: blu = zone più basse, verde/giallo = intermedie, rosso = zone più alte.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var waterSection: some View {
        VStack(spacing: 14) {
            sectionTitle("Simulazione deflusso", "Stima del percorso naturale dell’acqua verso le quote inferiori.")

            SurfaceHeatmap(metrics: metrics, mode: .water(intensity: rainIntensity), selectedIndex: .constant(nil))
                .frame(height: 330)

            VStack(spacing: 9) {
                HStack {
                    Text("INTENSITÀ PIOGGIA")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(rainIntensity < 0.34 ? "Leggera" : rainIntensity < 0.7 ? "Media" : "Forte")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.cyan)
                }
                Slider(value: $rainIntensity, in: 0.05...1)
                    .tint(.cyan)
            }
            .padding(13)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            HStack(spacing: 10) {
                infoCard(title: "Avvallamento", value: metrics.depressionLabel, icon: "drop.triangle")
                infoCard(title: "Percorso", value: metrics.flowPath.count > 2 ? "Rilevato" : "Limitato", icon: "point.topleft.down.curvedto.point.bottomright.up")
            }
        }
    }

    private var issuesSection: some View {
        VStack(spacing: 14) {
            sectionTitle("Risultati e problemi", "DrainMap evidenzia zone che meritano una verifica sul posto.")

            SurfaceHeatmap(metrics: metrics, mode: .depressions, selectedIndex: .constant(lowPointIndex))
                .frame(height: 270)

            VStack(spacing: 9) {
                ForEach(metrics.issues) { issue in
                    HStack(spacing: 12) {
                        Image(systemName: issue.systemImage)
                            .font(.title3)
                            .foregroundStyle(issueColor(issue.severity))
                            .frame(width: 30)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(issue.title)
                                .font(.subheadline.weight(.semibold))
                            Text(issue.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(12)
                    .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                }
            }

            Text("Indicazioni orientative basate sul rilievo LiDAR: per verifiche esecutive o normative usa una strumentazione professionale.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var detailSection: some View {
        VStack(spacing: 14) {
            sectionTitle("Dettaglio misura", "Tocca un punto della mappa per leggerne quota e pendenza locale.")

            SurfaceHeatmap(metrics: metrics, mode: .altitude, selectedIndex: $selectedIndex)
                .frame(height: 320)

            if let details = selectedPointDetails {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        infoCard(title: "Quota", value: details.height, icon: "arrow.up.and.down")
                        infoCard(title: "Pendenza locale", value: details.slope, icon: "angle")
                    }
                    HStack(spacing: 10) {
                        infoCard(title: "Avvallamento", value: details.depression, icon: "drop")
                        infoCard(title: "Posizione", value: details.position, icon: "scope")
                    }
                }
            }
        }
    }

    private var profileSection: some View {
        VStack(spacing: 14) {
            sectionTitle("Sezioni e profili", "Profilo altimetrico orizzontale attraverso il punto selezionato.")

            ProfileChart(metrics: metrics, selectedIndex: selectedIndex ?? lowPointIndex)
                .frame(height: 245)
                .padding(12)
                .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))

            HStack(spacing: 10) {
                infoCard(title: "Escursione quota", value: metrics.reliefLabel, icon: "arrow.up.and.down")
                infoCard(title: "Pendenza media", value: String(format: "%.1f%%", metrics.slopePercent), icon: "chart.line.uptrend.xyaxis")
            }

            Text("Il profilo segue la riga della mappa che attraversa il punto selezionato in Dettaglio. Se non selezioni nulla viene usato il punto più basso.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var reportSection: some View {
        VStack(spacing: 14) {
            sectionTitle("Esporta report", "Riepilogo pronto da condividere con misure, criticità e mappa.")

            reportPreview

            Button {
                reportURL = DrainMapReportBuilder.makeReport(metrics: metrics, measuredAt: measuredAt)
                showShareSheet = reportURL != nil
            } label: {
                Label("Genera e condividi PDF", systemImage: "square.and.arrow.up")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.black)
            .background(Color.cyan, in: RoundedRectangle(cornerRadius: 16, style: .continuous))

            if let onNewScan {
                Button {
                    onNewScan()
                } label: {
                    Label("Nuovo rilievo", systemImage: "viewfinder")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .frame(height: 48)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            }
        }
    }

    private var reportPreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("DRAINMAP")
                        .font(.caption.weight(.bold))
                        .tracking(2)
                        .foregroundStyle(.blue)
                    Text("Report superficie")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.black)
                    Text(measuredAt.formatted(date: .long, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
                Spacer()
                Image(systemName: "doc.text.fill")
                    .font(.title)
                    .foregroundStyle(.blue)
            }

            HStack(spacing: 8) {
                reportMetric("Pendenza", String(format: "%.1f%%", metrics.slopePercent))
                reportMetric("Min", metrics.minimumHeightLabel)
                reportMetric("Max", metrics.maximumHeightLabel)
            }

            SurfaceHeatmap(metrics: metrics, mode: .altitude, selectedIndex: .constant(nil), lightBackground: true)
                .frame(height: 180)

            Divider()

            ForEach(metrics.issues.prefix(3)) { issue in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: issue.systemImage)
                        .foregroundStyle(issueColor(issue.severity))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(issue.title).font(.caption.weight(.semibold)).foregroundStyle(.black)
                        Text(issue.detail).font(.caption2).foregroundStyle(.gray)
                    }
                }
            }
        }
        .padding(18)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func reportMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.gray)
            Text(value)
                .font(.headline.weight(.semibold))
                .foregroundStyle(.black)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func sectionTitle(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.title2.weight(.bold))
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func infoCard(title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(.cyan)
            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.weight(.semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private func issueColor(_ severity: SurfaceIssue.Severity) -> Color {
        switch severity {
        case .info: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    private var selectedPointDetails: (height: String, slope: String, depression: String, position: String)? {
        guard let selectedIndex,
              metrics.surfaceGrid.indices.contains(selectedIndex),
              metrics.surfaceGrid[selectedIndex] >= 0,
              metrics.gridColumns > 0 else { return nil }

        let normalized = metrics.surfaceGrid[selectedIndex]
        let heightMM = metrics.minimumHeightMillimeters + normalized * metrics.reliefMillimeters
        let localSlope = metrics.localSlopeGrid.indices.contains(selectedIndex) ? metrics.localSlopeGrid[selectedIndex] : -1
        let depression = metrics.depressionGrid.indices.contains(selectedIndex) ? metrics.depressionGrid[selectedIndex] : -1
        let column = selectedIndex % metrics.gridColumns
        let row = selectedIndex / metrics.gridColumns

        return (
            String(format: "%+.0f mm", heightMM),
            localSlope >= 0 ? String(format: "%.1f%%", localSlope) : "—",
            depression >= 0 ? String(format: "%.0f mm", depression) : "—",
            "C\(column + 1) · R\(row + 1)"
        )
    }
}

private enum HeatmapMode {
    case altitude
    case water(intensity: Double)
    case depressions
}

private struct SurfaceHeatmap: View {
    let metrics: ScanMetrics
    let mode: HeatmapMode
    @Binding var selectedIndex: Int?
    var lightBackground = false

    var body: some View {
        GeometryReader { geometry in
            let columns = max(metrics.gridColumns, 1)
            let rows = max(metrics.gridRows, 1)
            let count = columns * rows
            let values = metrics.surfaceGrid.count == count ? metrics.surfaceGrid : Array(repeating: -1, count: count)
            let spacing: CGFloat = 1.5
            let cellWidth = max(1, (geometry.size.width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
            let cellHeight = max(1, (geometry.size.height - CGFloat(rows - 1) * spacing) / CGFloat(rows))

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(lightBackground ? Color.black.opacity(0.05) : Color.black.opacity(0.28))

                ForEach(0..<count, id: \.self) { index in
                    let column = index % columns
                    let row = index / columns
                    let value = values[index]

                    Rectangle()
                        .fill(cellColor(index: index, value: value))
                        .frame(width: cellWidth, height: cellHeight)
                        .offset(
                            x: CGFloat(column) * (cellWidth + spacing),
                            y: CGFloat(row) * (cellHeight + spacing)
                        )
                }

                if metrics.flowPath.count > 1 {
                    Path { path in
                        guard let first = metrics.flowPath.first else { return }
                        path.move(to: CGPoint(x: CGFloat(first.x) * geometry.size.width, y: CGFloat(first.y) * geometry.size.height))
                        for point in metrics.flowPath.dropFirst() {
                            path.addLine(to: CGPoint(x: CGFloat(point.x) * geometry.size.width, y: CGFloat(point.y) * geometry.size.height))
                        }
                    }
                    .stroke(lightBackground ? Color.black.opacity(0.72) : Color.white.opacity(0.95), style: StrokeStyle(lineWidth: 2.3, lineCap: .round, lineJoin: .round, dash: [6, 4]))
                    .shadow(color: .cyan.opacity(lightBackground ? 0.15 : 0.8), radius: 4)
                }

                if let selectedIndex,
                   selectedIndex >= 0,
                   selectedIndex < count {
                    let column = selectedIndex % columns
                    let row = selectedIndex / columns
                    Circle()
                        .stroke(.white, lineWidth: 2.2)
                        .background(Circle().fill(.black.opacity(0.22)))
                        .frame(width: 22, height: 22)
                        .shadow(color: .cyan, radius: 7)
                        .position(
                            x: CGFloat(column) * (cellWidth + spacing) + cellWidth / 2,
                            y: CGFloat(row) * (cellHeight + spacing) + cellHeight / 2
                        )
                } else {
                    Circle()
                        .stroke(.white, lineWidth: 1.8)
                        .background(Circle().fill(.cyan.opacity(0.28)))
                        .frame(width: 18, height: 18)
                        .shadow(color: .cyan, radius: 6)
                        .position(
                            x: min(max(CGFloat(metrics.lowPointX) * geometry.size.width, 9), geometry.size.width - 9),
                            y: min(max(CGFloat(metrics.lowPointY) * geometry.size.height, 9), geometry.size.height - 9)
                        )
                }

                VStack {
                    Spacer()
                    HStack {
                        Text("BASSO")
                        Spacer()
                        Text("ALTO")
                    }
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(lightBackground ? .black.opacity(0.7) : .white.opacity(0.9))
                    .padding(8)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onEnded { gesture in
                        guard geometry.size.width > 0, geometry.size.height > 0 else { return }
                        let column = min(columns - 1, max(0, Int(gesture.location.x / geometry.size.width * CGFloat(columns))))
                        let row = min(rows - 1, max(0, Int(gesture.location.y / geometry.size.height * CGFloat(rows))))
                        let index = row * columns + column
                        if metrics.surfaceGrid.indices.contains(index), metrics.surfaceGrid[index] >= 0 {
                            selectedIndex = index
                            UISelectionFeedbackGenerator().selectionChanged()
                        }
                    }
            )
        }
    }

    private func cellColor(index: Int, value: Double) -> Color {
        guard value >= 0 else { return lightBackground ? .black.opacity(0.025) : .white.opacity(0.025) }
        let clamped = min(max(value, 0), 1)

        switch mode {
        case .altitude:
            let hue = 0.66 - clamped * 0.66
            return Color(hue: hue, saturation: 0.86, brightness: 0.96).opacity(lightBackground ? 0.92 : 0.86)

        case .water(let intensity):
            let depth = pow(1 - clamped, 1.45) * (0.35 + intensity * 0.65)
            return Color(hue: 0.57, saturation: 0.88, brightness: 0.96).opacity(0.18 + depth * 0.78)

        case .depressions:
            let depression = metrics.depressionGrid.indices.contains(index) ? metrics.depressionGrid[index] : 0
            if depression >= 12 { return .red.opacity(0.88) }
            if depression >= 6 { return .orange.opacity(0.86) }
            if depression >= 2 { return .yellow.opacity(0.72) }
            return .green.opacity(0.52)
        }
    }
}

private struct ProfileChart: View {
    let metrics: ScanMetrics
    let selectedIndex: Int?

    private var row: Int {
        guard metrics.gridColumns > 0, let selectedIndex else { return max(metrics.gridRows / 2, 0) }
        return min(max(selectedIndex / metrics.gridColumns, 0), max(metrics.gridRows - 1, 0))
    }

    private var values: [Double] {
        guard metrics.gridColumns > 0,
              metrics.gridRows > 0,
              metrics.surfaceGrid.count == metrics.gridColumns * metrics.gridRows else { return [] }
        let start = row * metrics.gridColumns
        let end = min(start + metrics.gridColumns, metrics.surfaceGrid.count)
        return Array(metrics.surfaceGrid[start..<end])
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Path { path in
                    let horizontalLines = 4
                    for line in 0...horizontalLines {
                        let y = geometry.size.height * CGFloat(line) / CGFloat(horizontalLines)
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                    }
                }
                .stroke(.white.opacity(0.08), lineWidth: 1)

                if values.count > 1 {
                    Path { path in
                        for (index, value) in values.enumerated() where value >= 0 {
                            let x = geometry.size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1))
                            let y = geometry.size.height * CGFloat(1 - value)
                            if index == 0 {
                                path.move(to: CGPoint(x: x, y: y))
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(.cyan, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .shadow(color: .cyan.opacity(0.55), radius: 5)

                    ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                        if value >= 0, index.isMultiple(of: max(1, values.count / 6)) || index == values.count - 1 {
                            Circle()
                                .fill(.cyan)
                                .frame(width: 7, height: 7)
                                .position(
                                    x: geometry.size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1)),
                                    y: geometry.size.height * CGFloat(1 - value)
                                )
                        }
                    }
                }
            }
        }
    }
}

private enum DrainMapReportBuilder {
    static func makeReport(metrics: ScanMetrics, measuredAt: Date) -> URL? {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let stamp = ISO8601DateFormatter().string(from: measuredAt).replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DrainMap-Report-\(stamp).pdf")

        do {
            try renderer.writePDF(to: url) { context in
                context.beginPage()
                let cg = context.cgContext

                UIColor.white.setFill()
                cg.fill(page)

                draw("DRAINMAP", at: CGRect(x: 42, y: 42, width: 200, height: 24), font: .systemFont(ofSize: 12, weight: .bold), color: .systemBlue)
                draw("Report superficie", at: CGRect(x: 42, y: 70, width: 360, height: 34), font: .systemFont(ofSize: 26, weight: .bold), color: .black)
                draw(measuredAt.formatted(date: .long, time: .shortened), at: CGRect(x: 42, y: 106, width: 360, height: 20), font: .systemFont(ofSize: 10), color: .darkGray)

                drawMetric("Pendenza media", String(format: "%.1f%%", metrics.slopePercent), x: 42, y: 150)
                drawMetric("Quota minima", metrics.minimumHeightLabel, x: 216, y: 150)
                drawMetric("Quota massima", metrics.maximumHeightLabel, x: 390, y: 150)

                draw("Mappa altimetrica", at: CGRect(x: 42, y: 244, width: 250, height: 22), font: .systemFont(ofSize: 14, weight: .semibold), color: .black)
                drawHeatmap(metrics: metrics, in: CGRect(x: 42, y: 274, width: 511, height: 255), context: cg)

                draw("Analisi", at: CGRect(x: 42, y: 558, width: 250, height: 22), font: .systemFont(ofSize: 14, weight: .semibold), color: .black)
                var y: CGFloat = 590
                for issue in metrics.issues.prefix(4) {
                    draw("• \(issue.title)", at: CGRect(x: 52, y: y, width: 490, height: 20), font: .systemFont(ofSize: 11, weight: .semibold), color: .black)
                    draw(issue.detail, at: CGRect(x: 64, y: y + 20, width: 478, height: 32), font: .systemFont(ofSize: 9), color: .darkGray)
                    y += 55
                }

                draw("Rilievo LiDAR orientativo. Verificare le misure con strumentazione professionale per usi esecutivi o normativi.", at: CGRect(x: 42, y: 790, width: 511, height: 30), font: .systemFont(ofSize: 8), color: .gray)
            }
            return url
        } catch {
            return nil
        }
    }

    private static func drawMetric(_ title: String, _ value: String, x: CGFloat, y: CGFloat) {
        draw(title.uppercased(), at: CGRect(x: x, y: y, width: 150, height: 16), font: .systemFont(ofSize: 8, weight: .bold), color: .gray)
        draw(value, at: CGRect(x: x, y: y + 19, width: 150, height: 34), font: .systemFont(ofSize: 22, weight: .semibold), color: .black)
    }

    private static func drawHeatmap(metrics: ScanMetrics, in rect: CGRect, context: CGContext) {
        let columns = max(metrics.gridColumns, 1)
        let rows = max(metrics.gridRows, 1)
        guard metrics.surfaceGrid.count == columns * rows else { return }

        let cellWidth = rect.width / CGFloat(columns)
        let cellHeight = rect.height / CGFloat(rows)
        for index in metrics.surfaceGrid.indices {
            let value = metrics.surfaceGrid[index]
            guard value >= 0 else { continue }
            let column = index % columns
            let row = index / columns
            let hue = CGFloat(0.66 - min(max(value, 0), 1) * 0.66)
            UIColor(hue: hue, saturation: 0.86, brightness: 0.96, alpha: 1).setFill()
            context.fill(CGRect(
                x: rect.minX + CGFloat(column) * cellWidth,
                y: rect.minY + CGFloat(row) * cellHeight,
                width: cellWidth + 0.5,
                height: cellHeight + 0.5
            ))
        }

        UIColor.black.withAlphaComponent(0.16).setStroke()
        context.stroke(rect)
    }

    private static func draw(_ text: String, at rect: CGRect, font: UIFont, color: UIColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        (text as NSString).draw(
            in: rect,
            withAttributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        )
    }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private struct DrainMapOnboardingView: View {
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.01, green: 0.07, blue: 0.09)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 24) {
                Spacer()

                ZStack {
                    ForEach([96.0, 136.0, 176.0], id: \.self) { size in
                        Circle()
                            .stroke(.cyan.opacity(size == 96 ? 0.34 : 0.12), lineWidth: 1)
                            .frame(width: size, height: size)
                    }
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 49, weight: .ultraLight))
                        .foregroundStyle(.cyan)
                        .shadow(color: .cyan.opacity(0.65), radius: 14)
                }

                VStack(spacing: 8) {
                    Text("DRAINMAP")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .tracking(4)
                    Text("Scansiona la superficie. Leggi le pendenze. Segui l’acqua.")
                        .font(.headline.weight(.regular))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                VStack(spacing: 10) {
                    onboardingRow(icon: "viewfinder", number: "1", title: "Inquadra", text: "Punta l’iPhone verso pavimento, terrazza o altra superficie.")
                    onboardingRow(icon: "cube.transparent.fill", number: "2", title: "Scansiona in 3D", text: "Muoviti lentamente: la mesh LiDAR azzurra mostra cosa è stato acquisito.")
                    onboardingRow(icon: "square.grid.3x3.fill", number: "3", title: "Analizza", text: "Ottieni mappa altimetrica, pendenze, punto basso e criticità.")
                    onboardingRow(icon: "drop.fill", number: "4", title: "Simula il deflusso", text: "Segui il percorso stimato dell’acqua e genera il report PDF.")
                }
                .padding(.horizontal, 22)

                Spacer()

                VStack(spacing: 11) {
                    Button(action: onContinue) {
                        Text("Apri scanner LiDAR")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.black)
                    .background(.cyan, in: RoundedRectangle(cornerRadius: 17, style: .continuous))

                    Text("Elaborazione sul dispositivo. Nessun account necessario.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
            }
        }
        .preferredColorScheme(.dark)
    }

    private func onboardingRow(icon: String, number: String, title: String, text: String) -> some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(.cyan.opacity(0.10))
                    .frame(width: 50, height: 50)
                VStack(spacing: 1) {
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.cyan)
                    Text(number)
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.cyan)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.07), lineWidth: 1))
    }
}
