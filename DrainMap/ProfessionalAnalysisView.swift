import SwiftUI

struct ProfessionalAnalysisView: View {
    enum Section: String, CaseIterable, Identifiable {
        case water = "Deflusso"
        case slopes = "Pendenze"
        case issues = "Problemi"
        case detail = "Dettaglio"
        case profile = "Profilo"
        case report = "Report"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .water: return "drop.fill"
            case .slopes: return "thermometer.medium"
            case .issues: return "exclamationmark.triangle.fill"
            case .detail: return "scope"
            case .profile: return "chart.xyaxis.line"
            case .report: return "doc.text.fill"
            }
        }
    }

    enum SlopeView: String, CaseIterable, Identifiable {
        case top = "Vista cima"
        case threeD = "Vista 3D"
        case altimetry = "Altimetria"
        var id: String { rawValue }
    }

    @ObservedObject var scanner: LiDARScanner
    let metrics: ScanMetrics
    let onSave: () -> Void
    let onNewScan: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var section: Section = .water
    @State private var slopeView: SlopeView = .altimetry
    @State private var rainIntensity = 0.55
    @State private var simulationRunning = true
    @State private var saved = false
    @State private var reportURL: URL?
    @State private var showShare = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                VStack(spacing: 0) {
                    sectionPicker
                    ScrollView {
                        Group {
                            switch section {
                            case .water: waterSection
                            case .slopes: slopesSection
                            case .issues: issuesSection
                            case .detail: detailSection
                            case .profile: profileSection
                            case .report: reportSection
                            }
                        }
                        .padding(14)
                    }
                }
            }
            .navigationTitle("Analisi superficie")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        guard !saved else { return }
                        onSave()
                        saved = true
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    } label: {
                        Image(systemName: saved ? "checkmark" : "square.and.arrow.down")
                    }
                    .disabled(saved)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showShare) {
            if let reportURL {
                ProfessionalShareSheet(items: [reportURL])
            }
        }
    }

    private var sectionPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Section.allCases) { item in
                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) { section = item }
                    } label: {
                        Label(item.rawValue, systemImage: item.icon)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(section == item ? .black : .white)
                            .padding(.horizontal, 12)
                            .frame(height: 37)
                            .background(section == item ? Color.cyan : Color.white.opacity(0.08), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .background(.black.opacity(0.55))
    }

    private var waterSection: some View {
        VStack(spacing: 14) {
            title("Simulazione acqua", "Il velo blu e le particelle mostrano il percorso stimato dell’acqua sulla stessa superficie rilevata.")

            ScannerCameraView(
                scanner: scanner,
                mode: .water,
                rainIntensity: rainIntensity,
                animateWater: simulationRunning
            )
            .frame(height: 430)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.12)))

            VStack(spacing: 8) {
                HStack {
                    Text("INTENSITÀ PIOGGIA")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(rainLabel)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.cyan)
                }
                Slider(value: $rainIntensity, in: 0.15...1)
                    .tint(.cyan)
            }
            .padding(13)
            .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))

            Button {
                simulationRunning.toggle()
            } label: {
                Label(simulationRunning ? "Pausa simulazione" : "Avvia simulazione", systemImage: simulationRunning ? "pause.fill" : "play.fill")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.black)
            .background(Color.cyan, in: RoundedRectangle(cornerRadius: 16))

            HStack(spacing: 10) {
                infoCard("Avvallamento", metrics.depressionLabel, "drop.triangle")
                infoCard("Punto basso", metrics.minimumHeightLabel, "arrow.down.to.line.compact")
            }

            Text("Simulazione topografica orientativa: non è un calcolo CFD di portata o volume d’acqua.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var slopesSection: some View {
        VStack(spacing: 14) {
            title("Mappa pendenze", "La superficie è colorata in modo continuo: blu = basso, rosso = alto.")

            Picker("Vista", selection: $slopeView) {
                ForEach(SlopeView.allCases) { view in
                    Text(view.rawValue).tag(view)
                }
            }
            .pickerStyle(.segmented)

            Group {
                switch slopeView {
                case .altimetry:
                    ScannerCameraView(scanner: scanner, mode: .altimetry)
                case .top:
                    if let surface = scanner.latestSurface {
                        SurfaceModelView(surface: surface, cameraMode: .top)
                    }
                case .threeD:
                    if let surface = scanner.latestSurface {
                        SurfaceModelView(surface: surface, cameraMode: .threeD)
                    }
                }
            }
            .frame(height: 430)
            .clipShape(RoundedRectangle(cornerRadius: 22))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.12)))

            altitudeLegend

            HStack(spacing: 8) {
                infoCard("Pendenza", String(format: "%.1f%%", metrics.slopePercent), "angle")
                infoCard("Min", metrics.minimumHeightLabel, "arrow.down")
                infoCard("Max", metrics.maximumHeightLabel, "arrow.up")
            }
        }
    }

    private var issuesSection: some View {
        VStack(spacing: 14) {
            title("Problemi e ristagni", "Le aree blu più intense nella simulazione corrispondono ai minimi e agli avvallamenti più significativi.")

            ScannerCameraView(scanner: scanner, mode: .water, rainIntensity: 0.75, animateWater: false)
                .frame(height: 330)
                .clipShape(RoundedRectangle(cornerRadius: 22))

            ForEach(metrics.issues) { issue in
                HStack(spacing: 12) {
                    Image(systemName: issue.systemImage)
                        .font(.title3)
                        .foregroundStyle(issue.severity == .critical ? .red : issue.severity == .warning ? .orange : .green)
                        .frame(width: 30)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(issue.title).font(.subheadline.weight(.semibold))
                        Text(issue.detail).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 15))
            }

            if let warning = scanner.qualityAssessment.warning {
                Label(warning, systemImage: "waveform.path.ecg.rectangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var detailSection: some View {
        VStack(spacing: 14) {
            title("Dettaglio rilievo", "Riepilogo delle quote e della qualità della superficie ricostruita.")
            HStack(spacing: 10) {
                infoCard("Pendenza media", String(format: "%.2f%%", metrics.slopePercent), "angle")
                infoCard("Gradi", String(format: "%.2f°", metrics.slopeDegrees), "compass.drawing")
            }
            HStack(spacing: 10) {
                infoCard("Quota min", metrics.minimumHeightLabel, "arrow.down.to.line.compact")
                infoCard("Quota max", metrics.maximumHeightLabel, "arrow.up.to.line.compact")
            }
            HStack(spacing: 10) {
                infoCard("Dislivello", metrics.reliefLabel, "arrow.up.and.down")
                infoCard("Copertura", metrics.coverageLabel, "square.dashed")
            }
            HStack(spacing: 10) {
                infoCard("Punti", metrics.sampleCount.formatted(), "dot.radiowaves.left.and.right")
                infoCard("Qualità", scanner.qualityAssessment.label, "checkmark.seal")
            }
        }
    }

    private var profileSection: some View {
        VStack(spacing: 14) {
            title("Profilo altimetrico", "Sezione orizzontale della superficie attraverso il punto più basso rilevato.")
            SurfaceProfileView(metrics: metrics)
                .frame(height: 250)
                .padding(12)
                .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))
            HStack(spacing: 10) {
                infoCard("Escursione", metrics.reliefLabel, "arrow.up.and.down")
                infoCard("Avvallamento", metrics.depressionLabel, "drop")
            }
        }
    }

    private var reportSection: some View {
        VStack(spacing: 14) {
            title("Report", "Esporta i risultati principali del rilievo in PDF.")

            VStack(alignment: .leading, spacing: 10) {
                Text("DRAINMAP")
                    .font(.caption.weight(.bold))
                    .tracking(2)
                    .foregroundStyle(.cyan)
                Text("Rilievo superficie")
                    .font(.title2.weight(.bold))
                HStack(spacing: 10) {
                    infoCard("Pendenza", String(format: "%.1f%%", metrics.slopePercent), "angle")
                    infoCard("Dislivello", metrics.reliefLabel, "arrow.up.and.down")
                }
                Text("Punti: \(metrics.sampleCount.formatted()) · Copertura: \(metrics.coverageLabel) · Qualità: \(scanner.qualityAssessment.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
            .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 18))

            Button {
                reportURL = ProfessionalReportBuilder.make(metrics: metrics, quality: scanner.qualityAssessment.label)
                showShare = reportURL != nil
            } label: {
                Label("Genera e condividi PDF", systemImage: "square.and.arrow.up")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.black)
            .background(Color.cyan, in: RoundedRectangle(cornerRadius: 16))

            Button(action: onNewScan) {
                Label("Nuovo rilievo", systemImage: "viewfinder")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 15))
        }
    }

    private var rainLabel: String {
        rainIntensity < 0.38 ? "Leggera" : rainIntensity < 0.72 ? "Media" : "Forte"
    }

    private var altitudeLegend: some View {
        HStack(spacing: 10) {
            Text(metrics.minimumHeightLabel).font(.caption2.weight(.semibold))
            LinearGradient(colors: [.blue, .cyan, .green, .yellow, .orange, .red], startPoint: .leading, endPoint: .trailing)
                .frame(height: 12)
                .clipShape(Capsule())
            Text(metrics.maximumHeightLabel).font(.caption2.weight(.semibold))
        }
        .monospacedDigit()
        .padding(10)
        .background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 14))
    }

    private func title(_ title: String, _ subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.title2.weight(.bold))
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func infoCard(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon).foregroundStyle(.cyan)
            Text(title.uppercased())
                .font(.system(size: 8, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.headline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.68)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 15))
    }
}

private struct SurfaceProfileView: View {
    let metrics: ScanMetrics

    private var values: [Double] {
        guard metrics.gridColumns > 1,
              metrics.gridRows > 0,
              metrics.surfaceGrid.count == metrics.gridColumns * metrics.gridRows else { return [] }
        let row = min(max(Int(round(metrics.lowPointY * Double(metrics.gridRows - 1))), 0), metrics.gridRows - 1)
        let start = row * metrics.gridColumns
        let end = min(start + metrics.gridColumns, metrics.surfaceGrid.count)
        return Array(metrics.surfaceGrid[start..<end])
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Path { path in
                    for line in 0...4 {
                        let y = geometry.size.height * CGFloat(line) / 4
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: geometry.size.width, y: y))
                    }
                }
                .stroke(.white.opacity(0.08), lineWidth: 1)

                if values.count > 1 {
                    Path { path in
                        var didStart = false
                        for (index, value) in values.enumerated() where value >= 0 {
                            let x = geometry.size.width * CGFloat(index) / CGFloat(max(values.count - 1, 1))
                            let y = geometry.size.height * CGFloat(1 - value)
                            if !didStart {
                                path.move(to: CGPoint(x: x, y: y))
                                didStart = true
                            } else {
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                        }
                    }
                    .stroke(.cyan, style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                    .shadow(color: .cyan.opacity(0.5), radius: 5)
                }
            }
        }
    }
}
