import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var store: ScanStore

    var body: some View {
        NavigationStack {
            Group {
                if store.records.isEmpty {
                    ContentUnavailableView(
                        "Nessun rilievo",
                        systemImage: "viewfinder.circle",
                        description: Text("I rilievi salvati appariranno qui.")
                    )
                } else {
                    List {
                        ForEach(store.records) { record in
                            NavigationLink {
                                RecordDetailView(record: record)
                            } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text(String(format: "%.1f%%", record.slopePercent))
                                            .font(.title3.weight(.semibold))
                                            .monospacedDigit()
                                        Spacer()
                                        Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    HStack(spacing: 12) {
                                        Label(String(format: "%.2f°", record.slopeDegrees), systemImage: "angle")
                                        Label(String(format: "%.2f m", record.distanceMeters), systemImage: "ruler")
                                        if let relief = record.reliefMillimeters {
                                            Label(String(format: "%.0f mm", relief), systemImage: "arrow.up.and.down")
                                        }
                                    }
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                        }
                        .onDelete(perform: store.delete)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Rilievi")
            .toolbar {
                if !store.records.isEmpty {
                    EditButton()
                }
            }
        }
    }
}

private struct RecordDetailView: View {
    let record: ScanRecord

    private var shareText: String {
        var lines = [
            "DrainMap — Rilievo",
            "Data: \(record.createdAt.formatted(date: .numeric, time: .shortened))",
            String(format: "Pendenza: %.1f%% (%.2f°)", record.slopePercent, record.slopeDegrees),
            String(format: "Distanza: %.2f m", record.distanceMeters),
            String(format: "Qualità: %.0f%%", record.quality * 100)
        ]
        if let relief = record.reliefMillimeters {
            lines.append(String(format: "Dislivello rilevato: %.0f mm", relief))
        }
        if let depression = record.depressionMillimeters {
            lines.append(String(format: "Avvallamento stimato: %.0f mm", depression))
        }
        lines.append("Misura stimata tramite LiDAR. Verificare con strumenti professionali per usi tecnici o normativi.")
        return lines.joined(separator: "\n")
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 4) {
                    Text(String(format: "%.1f%%", record.slopePercent))
                        .font(.system(size: 64, weight: .light, design: .rounded))
                        .monospacedDigit()
                    Text(String(format: "%.2f°", record.slopeDegrees))
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 24)

                HStack(spacing: 12) {
                    detailCard("Distanza", String(format: "%.2f m", record.distanceMeters))
                    detailCard("Qualità", String(format: "%.0f%%", record.quality * 100))
                }

                if record.reliefMillimeters != nil || record.depressionMillimeters != nil {
                    HStack(spacing: 12) {
                        detailCard("Dislivello", record.reliefMillimeters.map { String(format: "%.0f mm", $0) } ?? "—")
                        detailCard("Avvallamento", record.depressionMillimeters.map { String(format: "%.0f mm", $0) } ?? "—")
                    }
                }

                if let count = record.sampleCount {
                    Label("Analisi basata su \(count) punti LiDAR", systemImage: "dot.scope")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Text(record.createdAt.formatted(date: .long, time: .standard))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("Dettaglio")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: shareText) {
                Image(systemName: "square.and.arrow.up")
            }
        }
    }

    private func detailCard(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(1.1)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
                .minimumScaleFactor(0.75)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}
