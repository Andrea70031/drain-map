import SwiftUI

struct SettingsView: View {
    var body: some View {
        NavigationStack {
            List {
                Section("DrainMap") {
                    LabeledContent("Versione", value: "1.0")
                    LabeledContent("Elaborazione", value: "Sul dispositivo")
                }

                Section("Privacy") {
                    Label("Nessun account richiesto", systemImage: "person.crop.circle.badge.checkmark")
                    Label("Nessun tracciamento", systemImage: "hand.raised")
                    Label("Le scansioni restano sul dispositivo", systemImage: "iphone")
                }

                Section("Come ottenere una buona misura") {
                    Text("Inquadra una superficie uniforme da circa 0,4 a 3 metri, muovi lentamente l’iPhone e attendi che la qualità sia Buona o Ottima.")
                        .foregroundStyle(.secondary)
                }

                Section {
                    Text("DrainMap stima la pendenza tramite dati LiDAR e ARKit. Verifica sempre con strumenti professionali quando la misura ha implicazioni strutturali, normative o di sicurezza.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Info")
        }
    }
}
