import Foundation
import simd

struct SurfaceGeometrySnapshot {
    let columns: Int
    let rows: Int
    let vertices: [SIMD3<Float>]
    let validMask: [Bool]
    let normalizedHeights: [Float]
    let absoluteHeights: [Double]
    let localSlopeGrid: [Double]
    let depressionGrid: [Double]
    let triangleIndices: [UInt32]
    let origin: SIMD3<Float>
    let right: SIMD3<Float>
    let forward: SIMD3<Float>
    let uMin: Float
    let uMax: Float
    let vMin: Float
    let vMax: Float
    let residualMADMillimeters: Double
    let connectedCoverage: Double
    let metrics: ScanMetrics

    var isValid: Bool {
        columns > 1 && rows > 1 && vertices.count == columns * rows && validMask.count == vertices.count
    }

    func vertex(column: Int, row: Int) -> SIMD3<Float>? {
        guard column >= 0, column < columns, row >= 0, row < rows else { return nil }
        let index = row * columns + column
        guard validMask.indices.contains(index), validMask[index] else { return nil }
        return vertices[index]
    }

    func vertex(normalizedX: Double, normalizedY: Double) -> SIMD3<Float>? {
        let column = min(max(Int(round(normalizedX * Double(max(columns - 1, 1)))), 0), max(columns - 1, 0))
        let row = min(max(Int(round(normalizedY * Double(max(rows - 1, 1)))), 0), max(rows - 1, 0))
        return vertex(column: column, row: row)
    }
}

struct WaterFlowSegment3D {
    let start: SIMD3<Float>
    let end: SIMD3<Float>
    let intensity: Float
}

struct WaterPool3D {
    let center: SIMD3<Float>
    let radius: Float
    let strength: Float
}

struct WaterFlowField {
    let segments: [WaterFlowSegment3D]
    let pools: [WaterPool3D]
    let mainPath: [SIMD3<Float>]

    static let empty = WaterFlowField(segments: [], pools: [], mainPath: [])
}

struct ScanQualityAssessment {
    let score: Double
    let isSufficient: Bool
    let warning: String?

    var label: String {
        switch score {
        case 0.82...: return "Ottima"
        case 0.68..<0.82: return "Buona"
        case 0.52..<0.68: return "Media"
        default: return "Bassa"
        }
    }
}
