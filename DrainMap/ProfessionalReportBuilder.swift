import SwiftUI
import UIKit

struct ProfessionalShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

enum ProfessionalReportBuilder {
    static func make(metrics: ScanMetrics, quality: String) -> URL? {
        let page = CGRect(x: 0, y: 0, width: 595, height: 842)
        let renderer = UIGraphicsPDFRenderer(bounds: page)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DrainMap-Report-\(UUID().uuidString.prefix(8)).pdf")

        do {
            try renderer.writePDF(to: url) { context in
                context.beginPage()
                UIColor.white.setFill()
                context.cgContext.fill(page)

                draw("DRAINMAP", frame: CGRect(x: 42, y: 42, width: 250, height: 22), font: .systemFont(ofSize: 12, weight: .bold), color: .systemBlue)
                draw("Report rilievo LiDAR", frame: CGRect(x: 42, y: 72, width: 450, height: 34), font: .systemFont(ofSize: 26, weight: .bold), color: .black)
                draw(Date().formatted(date: .long, time: .shortened), frame: CGRect(x: 42, y: 112, width: 450, height: 20), font: .systemFont(ofSize: 10), color: .darkGray)

                metric("Pendenza media", String(format: "%.2f%%", metrics.slopePercent), x: 42, y: 164)
                metric("Quota minima", metrics.minimumHeightLabel, x: 216, y: 164)
                metric("Quota massima", metrics.maximumHeightLabel, x: 390, y: 164)
                metric("Dislivello", metrics.reliefLabel, x: 42, y: 250)
                metric("Copertura", metrics.coverageLabel, x: 216, y: 250)
                metric("Qualità", quality, x: 390, y: 250)

                draw("Analisi", frame: CGRect(x: 42, y: 350, width: 200, height: 24), font: .systemFont(ofSize: 16, weight: .semibold), color: .black)
                var y: CGFloat = 386
                for issue in metrics.issues.prefix(5) {
                    draw("• \(issue.title)", frame: CGRect(x: 50, y: y, width: 500, height: 20), font: .systemFont(ofSize: 11, weight: .semibold), color: .black)
                    draw(issue.detail, frame: CGRect(x: 62, y: y + 21, width: 478, height: 34), font: .systemFont(ofSize: 9), color: .darkGray)
                    y += 58
                }

                draw(
                    "Rilievo LiDAR orientativo. Per verifiche esecutive o normative utilizzare strumentazione professionale.",
                    frame: CGRect(x: 42, y: 790, width: 511, height: 28),
                    font: .systemFont(ofSize: 8),
                    color: .gray
                )
            }
            return url
        } catch {
            return nil
        }
    }

    private static func metric(_ title: String, _ value: String, x: CGFloat, y: CGFloat) {
        draw(title.uppercased(), frame: CGRect(x: x, y: y, width: 150, height: 16), font: .systemFont(ofSize: 8, weight: .bold), color: .gray)
        draw(value, frame: CGRect(x: x, y: y + 18, width: 150, height: 32), font: .systemFont(ofSize: 21, weight: .semibold), color: .black)
    }

    private static func draw(_ text: String, frame: CGRect, font: UIFont, color: UIColor) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        text.draw(in: frame, withAttributes: [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ])
    }
}
