import SwiftUI

struct SettingsView: View {
    @AppStorage("didCompleteOnboarding") private var didCompleteOnboarding = false

    var body: some View {
        NavigationStack {
            List {
                Section("Procedura di rilievo") {
                    manualRow("1", "Inquadra", "Tieni visibile la superficie che vuoi confrontare, preferibilmente da circa 0,4 a 3 m.", "viewfinder")
                    manualRow("2", "Avvia scansione", "Muovi lentamente l’iPhone sull’intera zona. La mesh azzurra mostra ciò che il LiDAR sta ricostruendo.", "cube.transparent")
                    manualRow("3", "Aumenta la copertura", "Evita movimenti rapidi e passa anche sulle zone ancora poco lette prima di premere Analizza superficie.", "dot.radiowaves.left.and.right")
                    manualRow("4", "Analizza", "Apri mappa pendenze, deflusso, criticità, dettaglio dei punti e profilo della superficie.", "square.grid.3x3.fill")
                    manualRow("5", "Esporta", "Genera il report PDF direttamente dalla sezione Report dell’analisi.", "doc.text.fill")
                }

                Section("Come leggere i risultati") {
                    Label("Blu: quote più basse", systemImage: "arrow.down.circle")
                    Label("Verde/giallo: quote intermedie", systemImage: "circle.lefthalf.filled")
                    Label("Rosso: quote più alte", systemImage: "arrow.up.circle")
                    Label("Linea tratteggiata: percorso di deflusso stimato", systemImage: "drop")
                    Label("Cerchio: punto selezionato o quota minima", systemImage: "scope")
                }

                Section("Consigli pratici") {
                    Text("Per terrazze e pavimenti, cerca di vedere tutta l’area utile e scansionala da più posizioni mantenendo il telefono stabile. Superfici lucide, vetro, acqua già presente o luce estrema possono ridurre la qualità del dato LiDAR.")
                        .foregroundStyle(.secondary)
                }

                Section("DrainMap") {
                    LabeledContent("Versione", value: "1.0 · Build 3")
                    LabeledContent("Elaborazione", value: "Sul dispositivo")
                    LabeledContent("Account", value: "Non richiesto")
                    Button {
                        didCompleteOnboarding = false
                    } label: {
                        Label("Rivedi guida iniziale", systemImage: "sparkles.rectangle.stack")
                    }
                }

                Section("Privacy") {
                    Label("Nessun tracciamento", systemImage: "hand.raised")
                    Label("Le scansioni restano sul dispositivo", systemImage: "iphone")
                }

                Section {
                    Text("DrainMap fornisce una stima basata su LiDAR e ARKit. Per verifiche esecutive, strutturali, normative o di sicurezza, conferma sempre i risultati con strumentazione professionale.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Manuale")
        }
    }

    private func manualRow(_ number: String, _ title: String, _ text: String, _ icon: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .fill(.cyan.opacity(0.10))
                    .frame(width: 42, height: 42)
                VStack(spacing: 0) {
                    Image(systemName: icon)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.cyan)
                    Text(number)
                        .font(.system(size: 9, weight: .bold))
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
        }
        .padding(.vertical, 3)
    }
}
