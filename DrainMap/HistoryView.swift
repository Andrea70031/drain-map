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
                        description: Text("Le scansioni salvate con mappa, pendenze e deflusso appariranno qui.")
                    )
                } else {
                    List {
                        ForEach(store.records) { record in
                            NavigationLink {
                                RecordDetailView(record: record)
                            } label: {
                                HStack(spacing: 13) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                                            .fill(.cyan.opacity(0.10))
                                            .frame(width: 54, height: 54)
                                        Image(systemName: "square.grid.3x3.fill")
                                            .foregroundStyle(.cyan)
                                    }

                                    VStack(alignment: .leading, spacing: 6) {
                                        HStack {
                                            Text(String(format: "%.1f%%", record.slopePercent))
                                                .font(.title3.weight(.semibold))
                                                .monospacedDigit()
                                            Text("pendenza")
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                            Spacer()
                                        }

                                        HStack(spacing: 10) {
                                            Label(record.reliefMillimeters.map { String(format: "%.0f mm", $0) } ?? "—", systemImage: "arrow.up.and.down")
                                            if let coverage = record.coverage {
                                                Label("\(Int(coverage * 100))%", systemImage: "viewfinder")
                                            }
                                        }
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)

                                        Text(record.createdAt.formatted(date: .abbreviated, time: .shortened))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
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
    @State private var showFullAnalysis = false

    private var metrics: ScanMetrics { record.metricsSnapshot }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                VStack(spacing: 4) {
                    Text(String(format: "%.1f%%", record.slopePercent))
                        .font(.system(size: 64, weight: .light, design: .rounded))
                        .monospacedDigit()
                    Text(String(format: "%.2f°", record.slopeDegrees))
                        .foregroundStyle(.secondary)
                    Text("Pendenza media")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.cyan)
                }
                .padding(.top, 22)

                HStack(spacing: 12) {
                    detailCard("Quota min", metrics.minimumHeightLabel, "arrow.down.to.line.compact")
                    detailCard("Quota max", metrics.maximumHeightLabel, "arrow.up.to.line.compact")
                }

                HStack(spacing: 12) {
                    detailCard("Dislivello", metrics.reliefLabel, "arrow.up.and.down")
                    detailCard("Avvallamento", metrics.depressionLabel, "drop.triangle")
                }

                HStack(spacing: 12) {
                    detailCard("Copertura", metrics.coverageLabel, "viewfinder")
                    detailCard("Qualità", metrics.qualityLabel, "checkmark.seal")
                }

                Button {
                    showFullAnalysis = true
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "square.grid.2x2.fill")
                        Text("Apri analisi completa")
                            .fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 54)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black)
                .background(Color.cyan, in: RoundedRectangle(cornerRadius: 17, style: .continuous))

                VStack(alignment: .leading, spacing: 10) {
                    Text("ANALISI")
                        .font(.caption2.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(.secondary)

                    ForEach(metrics.issues) { issue in
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: issue.systemImage)
                                .foregroundStyle(issue.severity == .critical ? .red : issue.severity == .warning ? .orange : .green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(issue.title).font(.subheadline.weight(.semibold))
                                Text(issue.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(15)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))

                Text(record.createdAt.formatted(date: .long, time: .standard))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
        .navigationTitle("Rilievo")
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showFullAnalysis) {
            DrainMapAnalysisStudio(metrics: metrics, measuredAt: record.createdAt)
        }
    }

    private func detailCard(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon)
                .foregroundStyle(.cyan)
            Text(title.uppercased())
                .font(.caption2.weight(.bold))
                .tracking(0.9)
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
