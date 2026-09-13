import SwiftUI
import UIKit

struct ScanView: View {
    @EnvironmentObject private var store: ScanStore
    @StateObject private var scanner = LiDARScanner()
    @AppStorage("didCompleteOnboarding") private var didCompleteOnboarding = false

    @State private var showOnboarding = false
    @State private var analyzedMetrics: ScanMetrics?
    @State private var showSavedPulse = false

    private var displayMetrics: ScanMetrics {
        analyzedMetrics ?? scanner.metrics
    }

    private var hasAnalysis: Bool {
        analyzedMetrics != nil
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
                colors: [.black.opacity(0.54), .clear, .black.opacity(0.88)],
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

                    scanAreaOverlay

                    Spacer(minLength: 4)

                    if let metrics = analyzedMetrics {
                        analysisPanel(metrics)
                    } else {
                        scanControlPanel
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
        }
        .onAppear {
            if didCompleteOnboarding {
                scanner.start()
            } else {
                showOnboarding = true
            }
        }
        .onDisappear {
            scanner.pause()
        }
        .fullScreenCover(isPresented: $showOnboarding) {
            DrainMapOnboardingView {
                didCompleteOnboarding = true
                showOnboarding = false
                scanner.start()
            }
            .interactiveDismissDisabled()
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

            Text("DRAINMAP")
                .font(.caption2.weight(.bold))
                .tracking(2.2)
                .foregroundStyle(.cyan)
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private var statusText: String {
        if hasAnalysis { return "Analisi completata" }
        if scanner.isMeasuring { return "Rilievo in corso" }
        if scanner.isRunning { return "Fotocamera pronta" }
        return "Avvio LiDAR…"
    }

    private var statusColor: Color {
        if hasAnalysis { return .green }
        if scanner.isMeasuring { return .cyan }
        return .orange
    }

    private var guidanceCard: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(guidanceColor.opacity(0.14))
                    .frame(width: 40, height: 40)

                if hasAnalysis {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(guidanceColor)
                } else {
                    Text(scanner.isMeasuring ? "2" : "1")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(guidanceColor)
                }
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(guidanceTitle)
                    .font(.subheadline.weight(.semibold))
                Text(guidanceText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.10), lineWidth: 1))
    }

    private var guidanceColor: Color {
        hasAnalysis ? .green : .cyan
    }

    private var guidanceTitle: String {
        if hasAnalysis { return "Pendenza analizzata" }
        if scanner.isMeasuring { return "Riempi il riquadro con la superficie" }
        return "Inquadra la zona da misurare"
    }

    private var guidanceText: String {
        if hasAnalysis {
            return "Il risultato qui sotto è bloccato. La freccia indica la direzione di discesa."
        }
        if scanner.isMeasuring {
            return "Muovi lentamente l’iPhone mantenendo la superficie dentro il riquadro. Le celle colorate sono i punti letti dal LiDAR."
        }
        return "Porta pavimento, terrazza o superficie dentro il riquadro. DrainMap analizzerà solo quella zona."
    }

    private var scanAreaOverlay: some View {
        let metrics = displayMetrics
        let columns = metrics.gridColumns > 0 ? metrics.gridColumns : 11
        let rows = metrics.gridRows > 0 ? metrics.gridRows : 9
        let values = metrics.surfaceGrid.count == columns * rows
            ? metrics.surfaceGrid
            : Array(repeating: -1.0, count: columns * rows)

        return GeometryReader { geometry in
            let spacing: CGFloat = 3
            let cellWidth = max(1, (geometry.size.width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
            let cellHeight = max(1, (geometry.size.height - CGFloat(rows - 1) * spacing) / CGFloat(rows))

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(.black.opacity(0.08))

                ForEach(0..<(columns * rows), id: \.self) { index in
                    let column = index % columns
                    let row = index / columns
                    let value = values[index]

                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(scanCellColor(value, analyzed: hasAnalysis))
                        .overlay(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .stroke(.white.opacity(value >= 0 ? 0.10 : 0.045), lineWidth: 0.7)
                        )
                        .frame(width: cellWidth, height: cellHeight)
                        .offset(
                            x: CGFloat(column) * (cellWidth + spacing),
                            y: CGFloat(row) * (cellHeight + spacing)
                        )
                }

                if metrics.hasMeasurement, metrics.flowPath.count > 1 {
                    Path { path in
                        guard let first = metrics.flowPath.first else { return }
                        path.move(to: CGPoint(
                            x: CGFloat(first.x) * geometry.size.width,
                            y: CGFloat(first.y) * geometry.size.height
                        ))
                        for point in metrics.flowPath.dropFirst() {
                            path.addLine(to: CGPoint(
                                x: CGFloat(point.x) * geometry.size.width,
                                y: CGFloat(point.y) * geometry.size.height
                            ))
                        }
                    }
                    .stroke(.white.opacity(hasAnalysis ? 0.95 : 0.55), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [6, 5]))
                    .shadow(color: .cyan.opacity(0.8), radius: 4)
                }

                if metrics.hasMeasurement {
                    Circle()
                        .stroke(.white, lineWidth: 1.6)
                        .background(Circle().fill(.cyan.opacity(0.34)))
                        .frame(width: 18, height: 18)
                        .shadow(color: .cyan, radius: 6)
                        .position(
                            x: min(max(CGFloat(metrics.lowPointX) * geometry.size.width, 9), geometry.size.width - 9),
                            y: min(max(CGFloat(metrics.lowPointY) * geometry.size.height, 9), geometry.size.height - 9)
                        )
                }

                VStack {
                    HStack {
                        Label(hasAnalysis ? "AREA ANALIZZATA" : "AREA DI RILIEVO", systemImage: hasAnalysis ? "checkmark.circle.fill" : "viewfinder")
                            .font(.system(size: 10, weight: .bold))
                            .tracking(0.9)
                            .foregroundStyle(.white)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(.black.opacity(0.58), in: Capsule())

                        Spacer()

                        if scanner.isMeasuring {
                            Text(metrics.hasMeasurement ? "\(Int(metrics.quality * 100))% letto" : "Acquisizione…")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 6)
                                .background(.black.opacity(0.58), in: Capsule())
                        }
                    }

                    Spacer()

                    HStack {
                        if scanner.isMeasuring {
                            Label("Muovi lentamente", systemImage: "move.3d")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.white.opacity(0.92))
                        } else if hasAnalysis {
                            Label("Cerchio = punto più basso", systemImage: "scope")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.white.opacity(0.92))
                        } else {
                            Label("Questa è la zona che verrà letta", systemImage: "scope")
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.white.opacity(0.92))
                        }
                        Spacer()
                    }
                    .padding(9)
                    .background(.black.opacity(0.38), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .padding(10)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(scanBorderColor, style: StrokeStyle(lineWidth: scanner.isMeasuring ? 2.4 : 1.5, dash: scanner.isMeasuring ? [] : [8, 7]))
            )
            .shadow(color: scanBorderColor.opacity(0.28), radius: scanner.isMeasuring ? 14 : 5)
        }
        .frame(height: 225)
        .padding(.horizontal, 10)
    }

    private var scanBorderColor: Color {
        if hasAnalysis { return .green }
        if scanner.isMeasuring { return .cyan }
        return .white.opacity(0.60)
    }

    private func scanCellColor(_ value: Double, analyzed: Bool) -> Color {
        guard value >= 0 else { return .clear }
        let clamped = min(max(value, 0), 1)
        if analyzed {
            let hue = 0.53 - clamped * 0.42
            return Color(hue: hue, saturation: 0.80, brightness: 0.96).opacity(0.48)
        }
        return Color.cyan.opacity(0.18 + clamped * 0.22)
    }

    private var scanControlPanel: some View {
        VStack(spacing: 12) {
            if scanner.isMeasuring {
                VStack(spacing: 8) {
                    HStack {
                        Text("COPERTURA LIDAR")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(1.2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(scanner.metrics.hasMeasurement ? scanner.metrics.qualityLabel : "Ricerca punti…")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(scanner.metrics.hasMeasurement ? .cyan : .secondary)
                    }

                    ProgressView(value: scanner.metrics.hasMeasurement ? scanner.metrics.quality : 0)
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
                            title: "PUNTI",
                            value: scanner.metrics.hasMeasurement ? "\(scanner.metrics.sampleCount)" : "—"
                        )
                    }
                }

                HStack(spacing: 10) {
                    Button(action: cancelMeasurement) {
                        Text("Annulla")
                            .fontWeight(.semibold)
                            .frame(width: 88, height: 50)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    Button(action: completeAnalysis) {
                        HStack(spacing: 9) {
                            Image(systemName: "chart.line.uptrend.xyaxis")
                            Text(scanner.metrics.hasMeasurement ? "Analizza pendenza" : "Sto leggendo…")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 50)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(scanner.metrics.hasMeasurement ? .black : .white.opacity(0.55))
                    .background(scanner.metrics.hasMeasurement ? Color.cyan : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .disabled(!scanner.metrics.hasMeasurement)
                }

                Text("Quando le celle si colorano, premi “Analizza pendenza” per bloccare il risultato.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else {
                Button(action: startMeasurement) {
                    HStack(spacing: 10) {
                        Image(systemName: "viewfinder")
                        Text("Avvia rilievo")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black)
                .background(scanner.isRunning ? Color.cyan : Color.gray, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                .disabled(!scanner.isRunning)

                Text("1. Inquadra  ·  2. Avvia rilievo  ·  3. Analizza pendenza")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(15)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private func analysisPanel(_ metrics: ScanMetrics) -> some View {
        VStack(spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("RISULTATO PENDENZA")
                        .font(.caption2.weight(.bold))
                        .tracking(1.5)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(String(format: "%.1f", metrics.slopePercent))
                            .font(.system(size: 44, weight: .light, design: .rounded))
                            .monospacedDigit()
                        Text("%")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.cyan)
                    }

                    Text("\(String(format: "%.2f°", metrics.slopeDegrees)) · \(slopeDescription(metrics.slopePercent))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(.cyan.opacity(0.10))
                            .frame(width: 72, height: 72)
                        Circle()
                            .stroke(.cyan.opacity(0.35), lineWidth: 1)
                            .frame(width: 72, height: 72)
                        Image(systemName: "arrow.up")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(.cyan)
                            .rotationEffect(.radians(metrics.downhillAngleRadians))
                            .shadow(color: .cyan.opacity(0.75), radius: 8)
                    }
                    Text("DISCESA")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1.1)
                        .foregroundStyle(.secondary)
                }
            }

            surfaceMap(metrics)

            HStack(spacing: 8) {
                metricChip(title: "DISLIVELLO", value: metrics.reliefLabel)
                metricChip(title: "AVVALLAMENTO", value: metrics.depressionLabel)
                metricChip(title: "QUALITÀ", value: metrics.qualityLabel)
            }

            HStack(spacing: 10) {
                Button(action: newMeasurement) {
                    HStack(spacing: 7) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Nuovo")
                            .fontWeight(.semibold)
                    }
                    .frame(width: 100, height: 48)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white)
                .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 15, style: .continuous))

                Button(action: saveMeasurement) {
                    HStack(spacing: 9) {
                        Image(systemName: showSavedPulse ? "checkmark" : "square.and.arrow.down")
                        Text(showSavedPulse ? "Rilievo salvato" : "Salva rilievo")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black)
                .background(Color.cyan, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .disabled(showSavedPulse)
            }
        }
        .padding(15)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private func surfaceMap(_ metrics: ScanMetrics) -> some View {
        VStack(spacing: 7) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MAPPA PENDENZE")
                        .font(.caption2.weight(.bold))
                        .tracking(1.2)
                    Text("Azzurro = basso · giallo/rosso = alto")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(metrics.sampleCount) punti")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.cyan)
            }

            GeometryReader { geometry in
                let columns = max(metrics.gridColumns, 1)
                let rows = max(metrics.gridRows, 1)
                let spacing: CGFloat = 2
                let cellWidth = max(1, (geometry.size.width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
                let cellHeight = max(1, (geometry.size.height - CGFloat(rows - 1) * spacing) / CGFloat(rows))

                ZStack(alignment: .topLeading) {
                    ForEach(Array(metrics.surfaceGrid.enumerated()), id: \.offset) { item in
                        let index = item.offset
                        let value = item.element
                        let column = index % columns
                        let row = index / columns

                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(surfaceColor(value))
                            .frame(width: cellWidth, height: cellHeight)
                            .offset(
                                x: CGFloat(column) * (cellWidth + spacing),
                                y: CGFloat(row) * (cellHeight + spacing)
                            )
                    }

                    if metrics.flowPath.count > 1 {
                        Path { path in
                            guard let first = metrics.flowPath.first else { return }
                            path.move(to: CGPoint(
                                x: CGFloat(first.x) * geometry.size.width,
                                y: CGFloat(first.y) * geometry.size.height
                            ))
                            for point in metrics.flowPath.dropFirst() {
                                path.addLine(to: CGPoint(
                                    x: CGFloat(point.x) * geometry.size.width,
                                    y: CGFloat(point.y) * geometry.size.height
                                ))
                            }
                        }
                        .stroke(.white.opacity(0.95), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [5, 4]))
                        .shadow(color: .cyan.opacity(0.8), radius: 3)
                    }

                    if let endPoint = metrics.flowPath.last {
                        Image(systemName: "drop.fill")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .shadow(color: .cyan, radius: 5)
                            .position(
                                x: CGFloat(endPoint.x) * geometry.size.width,
                                y: CGFloat(endPoint.y) * geometry.size.height
                            )
                    }

                    Circle()
                        .stroke(.white, lineWidth: 1.5)
                        .background(Circle().fill(.cyan.opacity(0.28)))
                        .frame(width: 16, height: 16)
                        .shadow(color: .cyan, radius: 6)
                        .position(
                            x: min(max(CGFloat(metrics.lowPointX) * geometry.size.width, 8), geometry.size.width - 8),
                            y: min(max(CGFloat(metrics.lowPointY) * geometry.size.height, 8), geometry.size.height - 8)
                        )
                }
            }
            .frame(height: 62)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(10)
        .background(.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.cyan.opacity(0.15), lineWidth: 1))
    }

    private func surfaceColor(_ value: Double) -> Color {
        guard value >= 0 else { return .white.opacity(0.035) }
        let clamped = min(max(value, 0), 1)
        let hue = 0.53 - clamped * 0.42
        return Color(hue: hue, saturation: 0.78, brightness: 0.94)
            .opacity(0.82)
    }

    private func slopeDescription(_ percent: Double) -> String {
        switch percent {
        case ..<0.5: return "quasi piano"
        case ..<2.0: return "pendenza lieve"
        case ..<5.0: return "pendenza media"
        default: return "pendenza marcata"
        }
    }

    private func metricChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
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

    private var unsupportedBackground: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "sensor.tag.radiowaves.forward")
                    .font(.system(size: 52, weight: .thin))
                    .foregroundStyle(.cyan)
                Text("LiDAR non disponibile")
                    .font(.title2.weight(.semibold))
                Text("Le misurazioni richiedono un iPhone dotato di sensore LiDAR.")
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
                Text("DrainMap usa fotocamera e LiDAR solo per analizzare la superficie in tempo reale. Abilita la fotocamera nelle Impostazioni per iniziare.")
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

    private func startMeasurement() {
        analyzedMetrics = nil
        showSavedPulse = false
        scanner.beginMeasurement()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func cancelMeasurement() {
        scanner.cancelMeasurement()
        analyzedMetrics = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func completeAnalysis() {
        guard scanner.metrics.hasMeasurement else { return }
        analyzedMetrics = scanner.metrics
        scanner.finishMeasurement()
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func newMeasurement() {
        analyzedMetrics = nil
        showSavedPulse = false
        scanner.beginMeasurement()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func saveMeasurement() {
        guard let analyzedMetrics else { return }
        store.add(ScanRecord(metrics: analyzedMetrics))
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) {
            showSavedPulse = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.3) {
            withAnimation { showSavedPulse = false }
        }
    }
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
                    Image(systemName: "viewfinder")
                        .font(.system(size: 48, weight: .ultraLight))
                        .foregroundStyle(.cyan)
                        .shadow(color: .cyan.opacity(0.65), radius: 14)
                }

                VStack(spacing: 8) {
                    Text("DRAINMAP")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .tracking(4)
                    Text("Misura la pendenza senza indovinare cosa sta leggendo il LiDAR.")
                        .font(.headline.weight(.regular))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                VStack(spacing: 11) {
                    onboardingRow(icon: "viewfinder", number: "1", title: "Inquadra", text: "Metti la superficie dentro il riquadro centrale: solo quella zona viene analizzata.")
                    onboardingRow(icon: "dot.radiowaves.left.and.right", number: "2", title: "Avvia il rilievo", text: "Muovi lentamente l’iPhone: le celle si colorano man mano che il LiDAR acquisisce punti.")
                    onboardingRow(icon: "chart.line.uptrend.xyaxis", number: "3", title: "Analizza la pendenza", text: "Blocca il rilievo e leggi percentuale, gradi, direzione di discesa, dislivello e punto basso.")
                }
                .padding(.horizontal, 22)

                Spacer()

                VStack(spacing: 11) {
                    Button(action: onContinue) {
                        Text("Apri fotocamera")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.black)
                    .background(.cyan, in: RoundedRectangle(cornerRadius: 17, style: .continuous))

                    Text("Richiede un iPhone con LiDAR. L’elaborazione avviene sul dispositivo.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
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
        .padding(12)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.07), lineWidth: 1))
    }
}
