import Foundation

struct ScanQualityEngine {
    let minimumPoints: Int
    let minimumCoverage: Double

    init(minimumPoints: Int = 15_000, minimumCoverage: Double = 0.60) {
        self.minimumPoints = minimumPoints
        self.minimumCoverage = minimumCoverage
    }

    func evaluate(
        pointCount: Int,
        coverage: Double,
        residualMADMillimeters: Double,
        connectedCoverage: Double
    ) -> ScanQualityAssessment {
        let pointScore = min(max(Double(pointCount) / Double(max(minimumPoints, 1)), 0), 1)
        let coverageScore = min(max(coverage / max(minimumCoverage, 0.01), 0), 1)
        let connectedScore = min(max(connectedCoverage / 0.72, 0), 1)

        let residualScore: Double
        switch residualMADMillimeters {
        case ..<4: residualScore = 1
        case 4..<8: residualScore = 0.90
        case 8..<15: residualScore = 0.72
        case 15..<25: residualScore = 0.48
        default: residualScore = 0.22
        }

        let score = min(max(
            pointScore * 0.24 +
            coverageScore * 0.36 +
            connectedScore * 0.22 +
            residualScore * 0.18,
            0
        ), 1)

        let enoughPoints = pointCount >= minimumPoints
        let enoughCoverage = coverage >= minimumCoverage
        let geometryStable = residualMADMillimeters <= 25 && connectedCoverage >= 0.45
        let isSufficient = enoughPoints && enoughCoverage && geometryStable && score >= 0.60

        let warning: String?
        if !enoughPoints {
            warning = "Servono ancora \(max(minimumPoints - pointCount, 0).formatted()) punti LiDAR validi."
        } else if !enoughCoverage {
            warning = "Copertura insufficiente: continua a muovere lentamente l’iPhone sull’intera superficie."
        } else if residualMADMillimeters > 25 {
            warning = "Rilievo instabile: sono presenti troppi salti di quota o oggetti fuori superficie."
        } else if connectedCoverage < 0.45 {
            warning = "Superficie troppo frammentata: inquadra una zona più continua."
        } else if score < 0.60 {
            warning = "Qualità del rilievo insufficiente. Ripeti lentamente la scansione."
        } else {
            warning = nil
        }

        return ScanQualityAssessment(score: score, isSufficient: isSufficient, warning: warning)
    }
}
