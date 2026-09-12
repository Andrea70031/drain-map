import ARKit
import Combine
import CoreVideo
import Foundation
import SceneKit
import SwiftUI
import simd

final class LiDARScanner: NSObject, ObservableObject, ARSessionDelegate {
    let session = ARSession()

    @Published private(set) var metrics = ScanMetrics()
    @Published private(set) var isSupported = true
    @Published private(set) var isRunning = false

    private var lastProcessedTimestamp: TimeInterval = 0

    override init() {
        super.init()
        session.delegate = self
    }

    func start() {
        guard ARWorldTrackingConfiguration.isSupported,
              ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            DispatchQueue.main.async { self.isSupported = false }
            return
        }

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = [.horizontal]
        configuration.frameSemantics.insert(.sceneDepth)
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }

        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        DispatchQueue.main.async {
            self.isSupported = true
            self.isRunning = true
        }
    }

    func pause() {
        session.pause()
        DispatchQueue.main.async { self.isRunning = false }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isRunning else { return }
        guard frame.timestamp - lastProcessedTimestamp > 0.12 else { return }
        lastProcessedTimestamp = frame.timestamp

        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }
        guard let result = analyze(depthData: depthData, frame: frame) else { return }

        DispatchQueue.main.async {
            self.metrics = result
        }
    }

    private struct SurfaceSample {
        let point: SIMD3<Float>
        let column: Int
        let row: Int
    }

    private func analyze(depthData: ARDepthData, frame: ARFrame) -> ScanMetrics? {
        let depthMap = depthData.depthMap
        let confidenceMap = depthData.confidenceMap

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        if let confidenceMap { CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
        }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return nil }
        let depthWidth = CVPixelBufferGetWidth(depthMap)
        let depthHeight = CVPixelBufferGetHeight(depthMap)
        let depthRowBytes = CVPixelBufferGetBytesPerRow(depthMap)

        let confidenceBase = confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confidenceRowBytes = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        let imageResolution = frame.camera.imageResolution
        let sx = Float(depthWidth) / Float(imageResolution.width)
        let sy = Float(depthHeight) / Float(imageResolution.height)
        let intrinsics = frame.camera.intrinsics
        let fx = intrinsics.columns.0.x * sx
        let fy = intrinsics.columns.1.y * sy
        let cx = intrinsics.columns.2.x * sx
        let cy = intrinsics.columns.2.y * sy

        let xStart = Int(Float(depthWidth) * 0.20)
        let xEnd = Int(Float(depthWidth) * 0.80)
        let yStart = Int(Float(depthHeight) * 0.25)
        let yEnd = Int(Float(depthHeight) * 0.75)
        let requestedColumns = 11
        let requestedRows = 9
        let xStep = max(1, (xEnd - xStart) / max(requestedColumns - 1, 1))
        let yStep = max(1, (yEnd - yStart) / max(requestedRows - 1, 1))
        let xValues = Array(stride(from: xStart, through: xEnd, by: xStep).prefix(requestedColumns))
        let yValues = Array(stride(from: yStart, through: yEnd, by: yStep).prefix(requestedRows))

        guard xValues.count >= 3, yValues.count >= 3 else { return nil }

        var samples: [SurfaceSample] = []
        var depthSum: Float = 0
        let candidateCount = xValues.count * yValues.count

        for (rowIndex, y) in yValues.enumerated() {
            for (columnIndex, x) in xValues.enumerated() {
                if let confidenceBase {
                    let confidenceRow = confidenceBase
                        .advanced(by: y * confidenceRowBytes)
                        .assumingMemoryBound(to: UInt8.self)
                    if confidenceRow[x] < 1 { continue }
                }

                let depthRow = depthBase
                    .advanced(by: y * depthRowBytes)
                    .assumingMemoryBound(to: Float32.self)
                let z = depthRow[x]
                guard z.isFinite, z > 0.15, z < 5.0 else { continue }

                let cameraX = (Float(x) - cx) * z / fx
                let cameraY = -(Float(y) - cy) * z / fy
                let cameraPoint = SIMD4<Float>(cameraX, cameraY, -z, 1)
                let worldPoint4 = frame.camera.transform * cameraPoint
                let point = SIMD3<Float>(worldPoint4.x, worldPoint4.y, worldPoint4.z)

                samples.append(SurfaceSample(point: point, column: columnIndex, row: rowIndex))
                depthSum += z
            }
        }

        guard samples.count >= 24 else { return nil }

        // Least-squares fit of the local surface: y = a*x + b*z + c.
        var sxx: Float = 0
        var sxz: Float = 0
        var sx1: Float = 0
        var szz: Float = 0
        var sz1: Float = 0
        var sxy: Float = 0
        var szy: Float = 0
        var sy1: Float = 0

        for sample in samples {
            let p = sample.point
            sxx += p.x * p.x
            sxz += p.x * p.z
            sx1 += p.x
            szz += p.z * p.z
            sz1 += p.z
            sxy += p.x * p.y
            szy += p.z * p.y
            sy1 += p.y
        }

        let n = Float(samples.count)
        let normalMatrix = simd_float3x3(
            SIMD3<Float>(sxx, sxz, sx1),
            SIMD3<Float>(sxz, szz, sz1),
            SIMD3<Float>(sx1, sz1, n)
        )

        guard abs(simd_determinant(normalMatrix)) > 0.000001 else { return nil }
        let coefficients = simd_inverse(normalMatrix) * SIMD3<Float>(sxy, szy, sy1)
        let a = coefficients.x
        let b = coefficients.y
        let c = coefficients.z

        let gradient = sqrt(a * a + b * b)
        let slopeDegrees = atan(gradient) * 180 / .pi
        let slopePercent = gradient * 100

        var downhill = SIMD3<Float>(-a, 0, -b)
        if simd_length(downhill) > 0.0001 {
            downhill = simd_normalize(downhill)
        }

        let transform = frame.camera.transform
        var right = SIMD3<Float>(transform.columns.0.x, 0, transform.columns.0.z)
        var forward = SIMD3<Float>(-transform.columns.2.x, 0, -transform.columns.2.z)
        if simd_length(right) > 0.001 { right = simd_normalize(right) }
        if simd_length(forward) > 0.001 { forward = simd_normalize(forward) }

        let rightComponent = simd_dot(downhill, right)
        let forwardComponent = simd_dot(downhill, forward)
        let downhillAngle = atan2(rightComponent, forwardComponent)

        let minY = samples.map(\.point.y).min() ?? 0
        let maxY = samples.map(\.point.y).max() ?? minY
        let verticalSpan = max(maxY - minY, 0.0001)
        let lowestSample = samples.min { $0.point.y < $1.point.y }

        var surfaceGrid = Array(repeating: -1.0, count: xValues.count * yValues.count)
        var minimumResidual: Float = 0

        for sample in samples {
            let normalizedHeight = Double((sample.point.y - minY) / verticalSpan)
            let index = sample.row * xValues.count + sample.column
            if surfaceGrid.indices.contains(index) {
                surfaceGrid[index] = min(max(normalizedHeight, 0), 1)
            }

            let fittedY = a * sample.point.x + b * sample.point.z + c
            minimumResidual = min(minimumResidual, sample.point.y - fittedY)
        }

        let quality = min(1, Double(samples.count) / Double(max(candidateCount, 1)))
        let lowPointX = lowestSample.map { Double($0.column) / Double(max(xValues.count - 1, 1)) } ?? 0.5
        let lowPointY = lowestSample.map { Double($0.row) / Double(max(yValues.count - 1, 1)) } ?? 0.5
        let flowPath = makeFlowPath(grid: surfaceGrid, columns: xValues.count, rows: yValues.count)

        return ScanMetrics(
            slopePercent: Double(slopePercent),
            slopeDegrees: Double(slopeDegrees),
            distanceMeters: Double(depthSum / Float(samples.count)),
            quality: quality,
            downhillAngleRadians: Double(downhillAngle),
            sampleCount: samples.count,
            hasMeasurement: true,
            surfaceGrid: surfaceGrid,
            gridColumns: xValues.count,
            gridRows: yValues.count,
            lowPointX: lowPointX,
            lowPointY: lowPointY,
            reliefMillimeters: Double(verticalSpan * 1000),
            depressionMillimeters: Double(max(0, -minimumResidual) * 1000),
            flowPath: flowPath
        )
    }

    private func makeFlowPath(grid: [Double], columns: Int, rows: Int) -> [SurfacePoint] {
        guard columns > 1, rows > 1, grid.count == columns * rows else { return [] }

        let centerColumn = columns / 2
        let centerRow = rows / 2
        let validIndices = grid.indices.filter { grid[$0] >= 0 }
        guard !validIndices.isEmpty else { return [] }

        let startIndex = validIndices.min { lhs, rhs in
            let lc = lhs % columns
            let lr = lhs / columns
            let rc = rhs % columns
            let rr = rhs / columns
            let ld = (lc - centerColumn) * (lc - centerColumn) + (lr - centerRow) * (lr - centerRow)
            let rd = (rc - centerColumn) * (rc - centerColumn) + (rr - centerRow) * (rr - centerRow)
            return ld < rd
        } ?? validIndices[0]

        var current = startIndex
        var visited: Set<Int> = []
        var result: [SurfacePoint] = []

        for _ in 0..<24 {
            if visited.contains(current) { break }
            visited.insert(current)

            let column = current % columns
            let row = current / columns
            result.append(
                SurfacePoint(
                    x: Double(column) / Double(columns - 1),
                    y: Double(row) / Double(rows - 1)
                )
            )

            let currentHeight = grid[current]
            var next = current
            var bestHeight = currentHeight

            for rowOffset in -1...1 {
                for columnOffset in -1...1 where !(rowOffset == 0 && columnOffset == 0) {
                    let nc = column + columnOffset
                    let nr = row + rowOffset
                    guard nc >= 0, nc < columns, nr >= 0, nr < rows else { continue }
                    let candidate = nr * columns + nc
                    let candidateHeight = grid[candidate]
                    guard candidateHeight >= 0 else { continue }

                    if candidateHeight < bestHeight - 0.004 {
                        bestHeight = candidateHeight
                        next = candidate
                    }
                }
            }

            if next == current { break }
            current = next
        }

        return result
    }
}

struct ScannerCameraView: UIViewRepresentable {
    @ObservedObject var scanner: LiDARScanner

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = scanner.session
        view.scene = SCNScene()
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}
