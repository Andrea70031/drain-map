import SwiftUI
import UIKit

struct ScanView: View {
    @EnvironmentObject private var store: ScanStore
    @StateObject private var scanner = LiDARScanner()
    @State private var showSavedPulse = false

    var body: some View {
        ZStack {
            if scanner.isSupported {
                ScannerCameraView(scanner: scanner)
                    .ignoresSafeArea()
            } else {
                unsupportedBackground
            }

            LinearGradient(
                colors: [.black.opacity(0.50), .clear, .black.opacity(0.78)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            VStack(spacing: 0) {
                statusBar
                    .padding(.top, 8)

                Spacer()

                reticle

                Spacer()

                measurementPanel
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
            }
        }
        .onAppear { scanner.start() }
        .onDisappear { scanner.pause() }
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
                .stroke(.cyan.opacity(0.28), lineWidth: 1)
                .frame(width: 126, height: 126)
            Circle()
                .stroke(.cyan.opacity(0.65), style: StrokeStyle(lineWidth: 1.5, dash: [5, 8]))
                .frame(width: 92, height: 92)
            Rectangle().fill(.cyan.opacity(0.85)).frame(width: 30, height: 1)
            Rectangle().fill(.cyan.opacity(0.85)).frame(width: 1, height: 30)
            Circle().fill(.cyan).frame(width: 5, height: 5).shadow(color: .cyan, radius: 8)
        }
        .allowsHitTesting(false)
    }

    private var measurementPanel: some View {
        VStack(spacing: 16) {
            HStack(alignment: .center, spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PENDENZA")
                        .font(.caption2.weight(.bold))
                        .tracking(1.8)
                        .foregroundStyle(.secondary)

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(scanner.metrics.hasMeasurement ? String(format: "%.1f", scanner.metrics.slopePercent) : "—")
                            .font(.system(size: 48, weight: .light, design: .rounded))
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

                ZStack {
                    Circle()
                        .fill(.cyan.opacity(0.10))
                        .frame(width: 82, height: 82)
                    Circle()
                        .stroke(.cyan.opacity(0.30), lineWidth: 1)
                        .frame(width: 82, height: 82)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(.cyan)
                        .rotationEffect(.radians(scanner.metrics.downhillAngleRadians))
                        .shadow(color: .cyan.opacity(0.7), radius: 8)
                }
            }

            HStack(spacing: 10) {
                metricChip(title: "DISTANZA", value: scanner.metrics.hasMeasurement ? String(format: "%.2f m", scanner.metrics.distanceMeters) : "—")
                metricChip(title: "QUALITÀ", value: scanner.metrics.hasMeasurement ? scanner.metrics.qualityLabel : "—")
            }

            Button(action: saveMeasurement) {
                HStack(spacing: 10) {
                    Image(systemName: showSavedPulse ? "checkmark" : "plus")
                    Text(showSavedPulse ? "Rilievo salvato" : "Salva rilievo")
                        .fontWeight(.semibold)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 52)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.black)
            .background(scanner.metrics.hasMeasurement ? Color.cyan : Color.gray, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .disabled(!scanner.metrics.hasMeasurement || showSavedPulse)
        }
        .padding(18)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(.white.opacity(0.12), lineWidth: 1))
    }

    private func metricChip(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
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
