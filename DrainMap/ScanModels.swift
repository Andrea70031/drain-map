import Foundation

struct SurfacePoint: Codable, Hashable {
    let x: Double
    let y: Double
}

struct SurfaceIssue: Identifiable, Hashable {
    enum Severity: String, Hashable {
        case info
        case warning
        case critical
    }

    let id = UUID()
    let title: String
    let detail: String
    let systemImage: String
    let severity: Severity
}

struct ScanMetrics: Equatable {
    var slopePercent: Double = 0
    var slopeDegrees: Double = 0
    var distanceMeters: Double = 0
    var quality: Double = 0
    var downhillAngleRadians: Double = 0
    var sampleCount: Int = 0
    var hasMeasurement = false

    var surfaceGrid: [Double] = []
    var gridColumns: Int = 0
    var gridRows: Int = 0
    var lowPointX: Double = 0.5
    var lowPointY: Double = 0.5
    var reliefMillimeters: Double = 0
    var depressionMillimeters: Double = 0
    var flowPath: [SurfacePoint] = []

    var coverage: Double = 0
    var meshAnchorCount: Int = 0
    var minimumHeightMillimeters: Double = 0
    var maximumHeightMillimeters: Double = 0
    var localSlopeGrid: [Double] = []
    var depressionGrid: [Double] = []

    var qualityLabel: String {
        switch quality {
        case 0.82...: return "Ottima"
        case 0.65..<0.82: return "Buona"
        case 0.45..<0.65: return "Media"
        default: return "Bassa"
        }
    }

    var coverageLabel: String {
        "\(Int(min(max(coverage, 0), 1) * 100))%"
    }

    var reliefLabel: String {
        guard hasMeasurement else { return "—" }
        return String(format: "%.0f mm", reliefMillimeters)
    }

    var depressionLabel: String {
        guard hasMeasurement else { return "—" }
        return String(format: "%.0f mm", depressionMillimeters)
    }

    var minimumHeightLabel: String {
        guard hasMeasurement else { return "—" }
        return String(format: "%+.0f mm", minimumHeightMillimeters)
    }

    var maximumHeightLabel: String {
        guard hasMeasurement else { return "—" }
        return String(format: "%+.0f mm", maximumHeightMillimeters)
    }

    var issues: [SurfaceIssue] {
        guard hasMeasurement else { return [] }
        var result: [SurfaceIssue] = []

        if depressionMillimeters >= 8 {
            result.append(
                SurfaceIssue(
                    title: "Possibile ristagno",
                    detail: String(format: "Avvallamento locale stimato di circa %.0f mm.", depressionMillimeters),
                    systemImage: "drop.triangle.fill",
                    severity: depressionMillimeters >= 15 ? .critical : .warning
                )
            )
        }

        if slopePercent < 1.0 {
            result.append(
                SurfaceIssue(
                    title: "Pendenza molto ridotta",
                    detail: String(format: "Pendenza media %.1f%%: il deflusso può risultare lento.", slopePercent),
                    systemImage: "exclamationmark.triangle.fill",
                    severity: .warning
                )
            )
        }

        if quality < 0.55 {
            result.append(
                SurfaceIssue(
                    title: "Rilievo da migliorare",
                    detail: "Ripeti la scansione più lentamente per aumentare copertura e affidabilità.",
                    systemImage: "waveform.path.ecg.rectangle",
                    severity: .info
                )
            )
        }

        if result.isEmpty {
            result.append(
                SurfaceIssue(
                    title: "Deflusso regolare",
                    detail: "Non emergono criticità evidenti nella zona rilevata.",
                    systemImage: "checkmark.circle.fill",
                    severity: .info
                )
            )
        }

        return result
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
    let reliefMillimeters: Double?
    let depressionMillimeters: Double?
    let sampleCount: Int?

    let coverage: Double?
    let minimumHeightMillimeters: Double?
    let maximumHeightMillimeters: Double?
    let surfaceGrid: [Double]?
    let localSlopeGrid: [Double]?
    let depressionGrid: [Double]?
    let gridColumns: Int?
    let gridRows: Int?
    let lowPointX: Double?
    let lowPointY: Double?
    let flowPath: [SurfacePoint]?

    init(metrics: ScanMetrics) {
        id = UUID()
        createdAt = Date()
        slopePercent = metrics.slopePercent
        slopeDegrees = metrics.slopeDegrees
        distanceMeters = metrics.distanceMeters
        quality = metrics.quality
        downhillAngleRadians = metrics.downhillAngleRadians
        reliefMillimeters = metrics.reliefMillimeters
        depressionMillimeters = metrics.depressionMillimeters
        sampleCount = metrics.sampleCount
        coverage = metrics.coverage
        minimumHeightMillimeters = metrics.minimumHeightMillimeters
        maximumHeightMillimeters = metrics.maximumHeightMillimeters
        surfaceGrid = metrics.surfaceGrid
        localSlopeGrid = metrics.localSlopeGrid
        depressionGrid = metrics.depressionGrid
        gridColumns = metrics.gridColumns
        gridRows = metrics.gridRows
        lowPointX = metrics.lowPointX
        lowPointY = metrics.lowPointY
        flowPath = metrics.flowPath
    }

    var metricsSnapshot: ScanMetrics {
        ScanMetrics(
            slopePercent: slopePercent,
            slopeDegrees: slopeDegrees,
            distanceMeters: distanceMeters,
            quality: quality,
            downhillAngleRadians: downhillAngleRadians,
            sampleCount: sampleCount ?? 0,
            hasMeasurement: true,
            surfaceGrid: surfaceGrid ?? [],
            gridColumns: gridColumns ?? 0,
            gridRows: gridRows ?? 0,
            lowPointX: lowPointX ?? 0.5,
            lowPointY: lowPointY ?? 0.5,
            reliefMillimeters: reliefMillimeters ?? 0,
            depressionMillimeters: depressionMillimeters ?? 0,
            flowPath: flowPath ?? [],
            coverage: coverage ?? quality,
            meshAnchorCount: 0,
            minimumHeightMillimeters: minimumHeightMillimeters ?? 0,
            maximumHeightMillimeters: maximumHeightMillimeters ?? (reliefMillimeters ?? 0),
            localSlopeGrid: localSlopeGrid ?? [],
            depressionGrid: depressionGrid ?? []
        )
    }
}
