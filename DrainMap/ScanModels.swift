import Foundation

struct ScanMetrics: Equatable {
    var slopePercent: Double = 0
    var slopeDegrees: Double = 0
    var distanceMeters: Double = 0
    var quality: Double = 0
    var downhillAngleRadians: Double = 0
    var sampleCount: Int = 0
    var hasMeasurement = false

    var qualityLabel: String {
        switch quality {
        case 0.8...: return "Ottima"
        case 0.6..<0.8: return "Buona"
        case 0.4..<0.6: return "Media"
        default: return "Bassa"
        }
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
