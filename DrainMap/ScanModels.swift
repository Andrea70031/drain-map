import Foundation

struct ScanMetrics: Equatable {
    var slopePercent: Double = 0
    var slopeDegrees: Double = 0
    var distanceMeters: Double = 0
    var quality: Double = 0
    var downhillAngleRadians: Double = 0
    var sampleCount: Int = 0
    var hasMeasurement = false

    // Live local surface map. Values are normalized from 0 (lowest) to 1 (highest).
    // A negative value means that the LiDAR sample was not reliable enough.
    var surfaceGrid: [Double] = []
    var gridColumns: Int = 0
    var gridRows: Int = 0
    var lowPointX: Double = 0.5
    var lowPointY: Double = 0.5
    var reliefMillimeters: Double = 0
    var depressionMillimeters: Double = 0

    var qualityLabel: String {
        switch quality {
        case 0.8...: return "Ottima"
        case 0.6..<0.8: return "Buona"
        case 0.4..<0.6: return "Media"
        default: return "Bassa"
        }
    }

    var reliefLabel: String {
        guard hasMeasurement else { return "—" }
        return String(format: "%.0f mm", reliefMillimeters)
    }

    var depressionLabel: String {
        guard hasMeasurement else { return "—" }
        return String(format: "%.0f mm", depressionMillimeters)
    }
}

struct ScanRecord: Identifiable, Codable, Hashable {
    let id: UUID
    let createdAt: Date
    let slopePercent: Double
    let slopeDegrees: Double
    let distanceMeters: Double
    let quality: Double
    let downhillAngleRadians: Double

    init(metrics: ScanMetrics) {
        id = UUID()
        createdAt = Date()
        slopePercent = metrics.slopePercent
        slopeDegrees = metrics.slopeDegrees
        distanceMeters = metrics.distanceMeters
        quality = metrics.quality
        downhillAngleRadians = metrics.downhillAngleRadians
    }
}
