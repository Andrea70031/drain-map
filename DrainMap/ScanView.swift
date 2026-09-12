import SwiftUI
import UIKit

struct ScanView: View {
    @EnvironmentObject private var store: ScanStore
    @StateObject private var scanner = LiDARScanner()
    @AppStorage("didCompleteOnboarding") private var didCompleteOnboarding = false
    @State private var showSavedPulse = false
    @State private var showSurfaceMap = true
    @State private var showOnboarding = false

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
                colors: [.black.opacity(0.50), .clear, .black.opacity(0.82)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            if !scanner.cameraDenied {
                VStack(spacing: 0) {
                    statusBar
                        .padding(.top, 8)

                    Spacer(minLength: 12)

                    reticle

                    Spacer(minLength: 12)

                    measurementPanel
                        .padding(.horizontal, 14)
                        .padding(.bottom, 10)
                }
            }
        }
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
    }

    private var statusBar: some View {
        HStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(scanner.metrics.hasMeasurement ? Color.cyan : Color.orange)
                    .frame(width: 8, height: 8)
                    .shadow(color: scanner.metrics.hasMeasurement ? .cyan : .orange, radius: 8)

                Text(scanner.metrics.hasMeasurement ? "LiDAR attivo" : "Ricerca superficie")
                    .font(.caption.weight(.semibold))
            }

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
        .padding(.horizontal, 16)
    }

    private var reticle: some View {
        ZStack {
            Circle()
                .stroke(.cyan.opacity(0.24), lineWidth: 1)
                .frame(width: 122, height: 122)
            Circle()
                .stroke(.cyan.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, dash: [5, 8]))
                .frame(width: 90, height: 90)
            Rectangle().fill(.cyan.opacity(0.85)).frame(width: 30, height: 1)
            Rectangle().fill(.cyan.opacity(0.85)).frame(width: 1, height: 30)
            Circle().fill(.cyan).frame(width: 5, height: 5).shadow(color: .cyan, radius: 8)
        }
        .allowsHitTesting(false)
    }

    private var measurementPanel: some View {
        VStack(spacing: 13) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PENDENZA")
                        .font(.caption2.weight(.bold))
                        .tracking(1.8)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(scanner.metrics.hasMeasurement ? String(format: "%.1f", scanner.metrics.slopePercent) : "—")
                            .font(.system(size: 44, weight: .light, design: .rounded))
                            .monospacedDigit()
                        Text("%")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.cyan)
                    }

                    Text(scanner.metrics.hasMeasurement ? String(format: "%.2f°", scanner.metrics.slopeDegrees) : "Inquadra una superficie")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(spacing: 6) {
                    ZStack {
                        Circle()
                            .fill(.cyan.opacity(0.10))
                            .frame(width: 74, height: 74)
                        Circle()
                            .stroke(.cyan.opacity(0.30), lineWidth: 1)
                            .frame(width: 74, height: 74)
                        Image(systemName: "arrow.up")
                            .font(.system(size: 31, weight: .light))
                            .foregroundStyle(.cyan)
                            .rotationEffect(.radians(scanner.metrics.downhillAngleRadians))
                            .shadow(color: .cyan.opacity(0.7), radius: 8)
                    }
                    Text("DISCESA")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)
                }
            }

            if showSurfaceMap, scanner.metrics.hasMeasurement, !scanner.metrics.surfaceGrid.isEmpty {
                surfaceMap
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }

            HStack(spacing: 8) {
                metricChip(title: "DISTANZA", value: scanner.metrics.hasMeasurement ? String(format: "%.2f m", scanner.metrics.distanceMeters) : "—")
                metricChip(title: "DISLIVELLO", value: scanner.metrics.reliefLabel)
                metricChip(title: "QUALITÀ", value: scanner.metrics.hasMeasurement ? scanner.metrics.qualityLabel : "—")
            }

            HStack(spacing: 10) {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { showSurfaceMap.toggle() }
                } label: {
                    Image(systemName: showSurfaceMap ? "square.grid.3x3.fill" : "square.grid.3x3")
                        .frame(width: 48, height: 48)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.cyan)
                .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .accessibilityLabel(showSurfaceMap ? "Nascondi mappa superficie" : "Mostra mappa superficie")

                Button(action: saveMeasurement) {
                    HStack(spacing: 10) {
                        Image(systemName: showSavedPulse ? "checkmark" : "plus")
                        Text(showSavedPulse ? "Rilievo salvato" : "Salva rilievo")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 48)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black)
                .background(scanner.metrics.hasMeasurement ? Color.cyan : Color.gray, in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                .disabled(!scanner.metrics.hasMeasurement || showSavedPulse)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private var surfaceMap: some View {
        VStack(spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("MAPPA SUPERFICIE")
                        .font(.caption2.weight(.bold))
                        .tracking(1.5)
                    Text("Basso → alto · linea = deflusso stimato")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: "scope")
                    Text("punto basso")
                }
                .font(.caption2.weight(.medium))
                .foregroundStyle(.cyan)
            }

            GeometryReader { geometry in
                let columns = max(scanner.metrics.gridColumns, 1)
                let rows = max(scanner.metrics.gridRows, 1)
                let spacing: CGFloat = 2
                let cellWidth = max(1, (geometry.size.width - CGFloat(columns - 1) * spacing) / CGFloat(columns))
                let cellHeight = max(1, (geometry.size.height - CGFloat(rows - 1) * spacing) / CGFloat(rows))

                ZStack(alignment: .topLeading) {
                    ForEach(Array(scanner.metrics.surfaceGrid.enumerated()), id: \.offset) { item in
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

                    if scanner.metrics.flowPath.count > 1 {
                        Path { path in
                            guard let first = scanner.metrics.flowPath.first else { return }
                            path.move(to: CGPoint(
                                x: CGFloat(first.x) * geometry.size.width,
                                y: CGFloat(first.y) * geometry.size.height
                            ))
                            for point in scanner.metrics.flowPath.dropFirst() {
                                path.addLine(to: CGPoint(
                                    x: CGFloat(point.x) * geometry.size.width,
                                    y: CGFloat(point.y) * geometry.size.height
                                ))
                            }
                        }
                        .stroke(.white.opacity(0.92), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [5, 4]))
                        .shadow(color: .cyan.opacity(0.8), radius: 3)
                    }

                    if let endPoint = scanner.metrics.flowPath.last {
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
                            x: min(max(CGFloat(scanner.metrics.lowPointX) * geometry.size.width, 8), geometry.size.width - 8),
                            y: min(max(CGFloat(scanner.metrics.lowPointY) * geometry.size.height, 8), geometry.size.height - 8)
                        )
                }
            }
            .frame(height: 70)
            .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

            HStack {
                Label("Avvallamento ~\(scanner.metrics.depressionLabel)", systemImage: "arrow.down.to.line.compact")
                Spacer()
                Text("\(scanner.metrics.sampleCount) punti")
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        .padding(11)
        .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(.cyan.opacity(0.15), lineWidth: 1))
    }

    private func surfaceColor(_ value: Double) -> Color {
        guard value >= 0 else { return .white.opacity(0.035) }
        let clamped = min(max(value, 0), 1)
        let hue = 0.53 - clamped * 0.42
        return Color(hue: hue, saturation: 0.78, brightness: 0.92)
            .opacity(0.78)
    }

    private func metricChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.9)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
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

    private func saveMeasurement() {
        guard scanner.metrics.hasMeasurement else { return }
        store.add(ScanRecord(metrics: scanner.metrics))
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { showSavedPulse = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
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

            VStack(spacing: 26) {
                Spacer()

                ZStack {
                    ForEach([96.0, 136.0, 176.0], id: \.self) { size in
                        Circle()
                            .stroke(.cyan.opacity(size == 96 ? 0.34 : 0.12), lineWidth: 1)
                            .frame(width: size, height: size)
                    }
                    Image(systemName: "arrow.down.and.line.horizontal.and.arrow.up")
                        .font(.system(size: 48, weight: .ultraLight))
                        .foregroundStyle(.cyan)
                        .shadow(color: .cyan.opacity(0.65), radius: 14)
                }

                VStack(spacing: 8) {
                    Text("DRAINMAP")
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .tracking(4)
                    Text("Leggi la superficie. Segui l’acqua.")
                        .font(.headline.weight(.regular))
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 12) {
                    onboardingRow(icon: "viewfinder", title: "Inquadra", text: "Punta l’iPhone verso pavimenti, terrazze o altre superfici.")
                    onboardingRow(icon: "square.grid.3x3.fill", title: "Analizza", text: "LiDAR calcola pendenza, dislivello, punto basso e irregolarità.")
                    onboardingRow(icon: "drop.fill", title: "Segui il deflusso", text: "La mappa mostra una stima del percorso naturale verso le zone più basse.")
                }
                .padding(.horizontal, 22)

                Spacer()

                VStack(spacing: 12) {
                    Button(action: onContinue) {
                        Text("Avvia scansione")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.black)
                    .background(.cyan, in: RoundedRectangle(cornerRadius: 17, style: .continuous))

                    Text("Richiede un iPhone con LiDAR. L’elaborazione avviene sul dispositivo e non richiede account.")
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

    private func onboardingRow(icon: String, title: String, text: String) -> some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(.cyan.opacity(0.10))
                    .frame(width: 48, height: 48)
                Image(systemName: icon)
                    .foregroundStyle(.cyan)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(13)
        .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(.white.opacity(0.07), lineWidth: 1))
    }
}
