import ARKit
import AVFoundation
import Combine
import CoreVideo
import Foundation
import SceneKit
import SwiftUI
import UIKit
import simd

struct LiveFlowVector: Equatable {
    let start: CGPoint
    let end: CGPoint
    let intensity: Double
}

struct LiveFlowPool: Equatable {
    let center: CGPoint
    let strength: Double
}

final class LiDARScanner: NSObject, ObservableObject, ARSessionDelegate {
    let session = ARSession()

    @Published private(set) var metrics = ScanMetrics()
    @Published private(set) var isSupported = true
    @Published private(set) var isRunning = false
    @Published private(set) var isMeasuring = false
    @Published private(set) var cameraDenied = false
    @Published private(set) var supportsMeshReconstruction = false
    @Published private(set) var acquiredPointCount = 0
    @Published private(set) var liveFlowVectors: [LiveFlowVector] = []
    @Published private(set) var liveFlowPools: [LiveFlowPool] = []

    let minimumRequiredPoints = 15_000
    let minimumRequiredCoverage = 0.60

    private let stateLock = NSLock()
    private var lastProcessedTimestamp: TimeInterval = 0
    private var accumulatedPoints: [SIMD3<Float>] = []
    private var accumulatedDepth: Double = 0
    private var accumulatedDepthCount = 0
    private var meshAnchorIDs: Set<UUID> = []
    private var lastCameraTransform = matrix_identity_float4x4

    private let requestedColumns = 25
    private let requestedRows = 19
    private let maximumAccumulatedPoints = 36_000
    private let liveAnalysisPointLimit = 8_000
    private let finalAnalysisPointLimit = 20_000
    private let frameInterval: TimeInterval = 0.12

    override init() {
        super.init()
        session.delegate = self
    }

    func start() {
        guard ARWorldTrackingConfiguration.isSupported,
              ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            DispatchQueue.main.async {
                self.isSupported = false
                self.isRunning = false
                self.isMeasuring = false
            }
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            DispatchQueue.main.async { self.cameraDenied = false }
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.start()
                } else {
                    DispatchQueue.main.async {
                        self.cameraDenied = true
                        self.isRunning = false
                        self.isMeasuring = false
                    }
                }
            }
        case .denied, .restricted:
            DispatchQueue.main.async {
                self.cameraDenied = true
                self.isRunning = false
                self.isMeasuring = false
            }
        @unknown default:
            DispatchQueue.main.async {
                self.cameraDenied = true
                self.isRunning = false
                self.isMeasuring = false
            }
        }
    }

    private func startSession() {
        resetAcquisition()

        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = [.horizontal]
        configuration.frameSemantics.insert(.sceneDepth)
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }

        let meshSupported = ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh)
        if meshSupported {
            configuration.sceneReconstruction = .mesh
        }

        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        DispatchQueue.main.async {
            self.isSupported = true
            self.isRunning = true
            self.isMeasuring = false
            self.supportsMeshReconstruction = meshSupported
            self.metrics = ScanMetrics()
            self.acquiredPointCount = 0
            self.liveFlowVectors = []
            self.liveFlowPools = []
        }
    }

    func beginMeasurement() {
        guard isRunning else { return }
        resetAcquisition()
        DispatchQueue.main.async {
            self.metrics = ScanMetrics()
            self.acquiredPointCount = 0
            self.liveFlowVectors = []
            self.liveFlowPools = []
            self.isMeasuring = true
        }
    }

    @discardableResult
    func finishMeasurement() -> ScanMetrics? {
        let snapshot = acquisitionSnapshot()
        let final = analyze(
            points: snapshot.points,
            averageDepth: snapshot.averageDepth,
            meshCount: snapshot.meshCount,
            cameraTransform: snapshot.cameraTransform,
            pointLimit: finalAnalysisPointLimit
        )

        DispatchQueue.main.async {
            self.isMeasuring = false
            self.liveFlowVectors = []
            self.liveFlowPools = []
            if let final { self.metrics = final }
        }
        return final ?? (metrics.hasMeasurement ? metrics : nil)
    }

    func cancelMeasurement() {
        resetAcquisition()
        DispatchQueue.main.async {
            self.metrics = ScanMetrics()
            self.acquiredPointCount = 0
            self.liveFlowVectors = []
            self.liveFlowPools = []
            self.isMeasuring = false
        }
    }

    func pause() {
        session.pause()
        DispatchQueue.main.async {
            self.isRunning = false
            self.isMeasuring = false
            self.liveFlowVectors = []
            self.liveFlowPools = []
        }
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        updateMeshAnchorIDs(anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        updateMeshAnchorIDs(anchors)
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        stateLock.lock()
        for anchor in anchors where anchor is ARMeshAnchor {
            meshAnchorIDs.remove(anchor.identifier)
        }
        stateLock.unlock()
    }

    private func updateMeshAnchorIDs(_ anchors: [ARAnchor]) {
        stateLock.lock()
        for anchor in anchors where anchor is ARMeshAnchor {
            meshAnchorIDs.insert(anchor.identifier)
        }
        stateLock.unlock()
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        stateLock.lock()
        lastCameraTransform = frame.camera.transform
        let shouldMeasure = isMeasuring
        let elapsed = frame.timestamp - lastProcessedTimestamp
        if shouldMeasure && elapsed > frameInterval {
            lastProcessedTimestamp = frame.timestamp
        }
        stateLock.unlock()

        guard shouldMeasure, elapsed > frameInterval else { return }
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }

        let frameData = extractFrameData(depthData: depthData, frame: frame)
        guard !frameData.points.isEmpty else { return }

        stateLock.lock()
        accumulatedPoints.append(contentsOf: frameData.points)
        accumulatedDepth += frameData.depthSum
        accumulatedDepthCount += frameData.depthCount
        if accumulatedPoints.count > maximumAccumulatedPoints {
            accumulatedPoints.removeFirst(accumulatedPoints.count - maximumAccumulatedPoints)
        }
        let points = accumulatedPoints
        let pointCount = accumulatedPoints.count
        let averageDepth = accumulatedDepthCount > 0 ? accumulatedDepth / Double(accumulatedDepthCount) : 0
        let meshCount = meshAnchorIDs.count
        let cameraTransform = lastCameraTransform
        stateLock.unlock()

        DispatchQueue.main.async {
            guard self.isMeasuring else { return }
            self.acquiredPointCount = pointCount
            self.liveFlowVectors = frameData.flowVectors
            self.liveFlowPools = frameData.flowPools
        }

        guard let live = analyze(
            points: points,
            averageDepth: averageDepth,
            meshCount: meshCount,
            cameraTransform: cameraTransform,
            pointLimit: liveAnalysisPointLimit
        ) else { return }

        DispatchQueue.main.async {
            guard self.isMeasuring else { return }
            self.metrics = live
        }
    }

    private func resetAcquisition() {
        stateLock.lock()
        lastProcessedTimestamp = 0
        accumulatedPoints.removeAll(keepingCapacity: true)
        accumulatedDepth = 0
        accumulatedDepthCount = 0
        meshAnchorIDs.removeAll(keepingCapacity: true)
        lastCameraTransform = matrix_identity_float4x4
        stateLock.unlock()
    }

    private func acquisitionSnapshot() -> (points: [SIMD3<Float>], averageDepth: Double, meshCount: Int, cameraTransform: simd_float4x4) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let averageDepth = accumulatedDepthCount > 0 ? accumulatedDepth / Double(accumulatedDepthCount) : 0
        return (accumulatedPoints, averageDepth, meshAnchorIDs.count, lastCameraTransform)
    }

    private struct FrameSample {
        let world: SIMD3<Float>
        let normalizedImagePoint: CGPoint
    }

    private struct FrameData {
        var points: [SIMD3<Float>]
        var depthSum: Double
        var depthCount: Int
        var flowVectors: [LiveFlowVector]
        var flowPools: [LiveFlowPool]
    }

    private func extractFrameData(depthData: ARDepthData, frame: ARFrame) -> FrameData {
        let depthMap = depthData.depthMap
        let confidenceMap = depthData.confidenceMap

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        if let confidenceMap { CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
        }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else {
            return FrameData(points: [], depthSum: 0, depthCount: 0, flowVectors: [], flowPools: [])
        }

        let width = CVPixelBufferGetWidth(depthMap)
        let height = CVPixelBufferGetHeight(depthMap)
        let rowBytes = CVPixelBufferGetBytesPerRow(depthMap)
        let confidenceBase = confidenceMap.flatMap { CVPixelBufferGetBaseAddress($0) }
        let confidenceRowBytes = confidenceMap.map { CVPixelBufferGetBytesPerRow($0) } ?? 0

        let imageResolution = frame.camera.imageResolution
        let sx = Float(width) / Float(imageResolution.width)
        let sy = Float(height) / Float(imageResolution.height)
        let intrinsics = frame.camera.intrinsics
        let fx = intrinsics.columns.0.x * sx
        let fy = intrinsics.columns.1.y * sy
        let cx = intrinsics.columns.2.x * sx
        let cy = intrinsics.columns.2.y * sy

        let xStart = Int(Float(width) * 0.10)
        let xEnd = Int(Float(width) * 0.90)
        let yStart = Int(Float(height) * 0.16)
        let yEnd = Int(Float(height) * 0.84)
        let sampleColumns = 33
        let sampleRows = 25
        let gridCount = sampleColumns * sampleRows

        var samples = Array<FrameSample?>(repeating: nil, count: gridCount)
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(gridCount)
        var depthSum = 0.0
        var depthCount = 0

        for row in 0..<sampleRows {
            let fyIndex = Double(row) / Double(max(sampleRows - 1, 1))
            let y = min(height - 1, max(0, Int(round(Double(yStart) + fyIndex * Double(yEnd - yStart)))))

            for column in 0..<sampleColumns {
                let fxIndex = Double(column) / Double(max(sampleColumns - 1, 1))
                let x = min(width - 1, max(0, Int(round(Double(xStart) + fxIndex * Double(xEnd - xStart)))))

                if let confidenceBase {
                    let confidenceRow = confidenceBase
                        .advanced(by: y * confidenceRowBytes)
                        .assumingMemoryBound(to: UInt8.self)
                    if confidenceRow[x] < 1 { continue }
                }

                let depthRow = depthBase
                    .advanced(by: y * rowBytes)
                    .assumingMemoryBound(to: Float32.self)
                let z = depthRow[x]
                guard z.isFinite, z > 0.22, z < 5.0 else { continue }

                let cameraX = (Float(x) - cx) * z / fx
                let cameraY = -(Float(y) - cy) * z / fy
                let cameraPoint = SIMD4<Float>(cameraX, cameraY, -z, 1)
                let worldPoint4 = frame.camera.transform * cameraPoint
                let world = SIMD3<Float>(worldPoint4.x, worldPoint4.y, worldPoint4.z)
                let normalized = CGPoint(
                    x: CGFloat(x) / CGFloat(max(width - 1, 1)),
                    y: CGFloat(y) / CGFloat(max(height - 1, 1))
                )

                samples[row * sampleColumns + column] = FrameSample(world: world, normalizedImagePoint: normalized)
                points.append(world)
                depthSum += Double(z)
                depthCount += 1
            }
        }

        let liveFlow = makeLiveFlow(samples: samples, columns: sampleColumns, rows: sampleRows)
        return FrameData(
            points: points,
            depthSum: depthSum,
            depthCount: depthCount,
            flowVectors: liveFlow.vectors,
            flowPools: liveFlow.pools
        )
    }

    private func makeLiveFlow(samples: [FrameSample?], columns: Int, rows: Int) -> (vectors: [LiveFlowVector], pools: [LiveFlowPool]) {
        guard samples.count == columns * rows else { return ([], []) }

        var smoothedY = Array<Double?>(repeating: nil, count: samples.count)
        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                guard let sample = samples[index] else { continue }
                var sum = Double(sample.world.y) * 2.0
                var weight = 2.0
                for dr in -1...1 {
                    for dc in -1...1 where !(dc == 0 && dr == 0) {
                        let nr = row + dr
                        let nc = column + dc
                        guard nr >= 0, nr < rows, nc >= 0, nc < columns,
                              let neighbor = samples[nr * columns + nc] else { continue }
                        sum += Double(neighbor.world.y)
                        weight += 1
                    }
                }
                smoothedY[index] = sum / weight
            }
        }

        var vectors: [LiveFlowVector] = []
        var pools: [LiveFlowPool] = []
        vectors.reserveCapacity(140)

        for row in stride(from: 1, to: rows - 1, by: 2) {
            for column in stride(from: 1, to: columns - 1, by: 2) {
                let index = row * columns + column
                guard let current = samples[index], let currentY = smoothedY[index] else { continue }

                var bestIndex: Int?
                var bestY = currentY
                var neighborYs: [Double] = []

                for dr in -1...1 {
                    for dc in -1...1 where !(dc == 0 && dr == 0) {
                        let nr = row + dr
                        let nc = column + dc
                        guard nr >= 0, nr < rows, nc >= 0, nc < columns else { continue }
                        let candidate = nr * columns + nc
                        guard let value = smoothedY[candidate], samples[candidate] != nil else { continue }
                        neighborYs.append(value)
                        if value < bestY {
                            bestY = value
                            bestIndex = candidate
                        }
                    }
                }

                if let bestIndex, let best = samples[bestIndex] {
                    let drop = currentY - bestY
                    let dx = Double(current.world.x - best.world.x)
                    let dz = Double(current.world.z - best.world.z)
                    let horizontalDistance = max(sqrt(dx * dx + dz * dz), 0.005)
                    let slopePercent = drop / horizontalDistance * 100.0

                    if slopePercent >= 0.18 {
                        let intensity = min(max(slopePercent / 6.0, 0.04), 1.0)
                        let start = current.normalizedImagePoint
                        let rawEnd = best.normalizedImagePoint
                        let vx = rawEnd.x - start.x
                        let vy = rawEnd.y - start.y
                        let extensionFactor: CGFloat = 1.75
                        let end = CGPoint(
                            x: min(max(start.x + vx * extensionFactor, 0), 1),
                            y: min(max(start.y + vy * extensionFactor, 0), 1)
                        )
                        vectors.append(LiveFlowVector(start: start, end: end, intensity: intensity))
                    }
                }

                if neighborYs.count >= 5 {
                    let neighborMean = neighborYs.reduce(0, +) / Double(neighborYs.count)
                    let depression = neighborMean - currentY
                    if depression >= 0.006 {
                        pools.append(
                            LiveFlowPool(
                                center: current.normalizedImagePoint,
                                strength: min(max(depression / 0.025, 0.15), 1.0)
                            )
                        )
                    }
                }
            }
        }

        if vectors.count > 150 {
            vectors = Array(vectors.prefix(150))
        }
        if pools.count > 24 {
            pools = Array(pools.sorted { $0.strength > $1.strength }.prefix(24))
        }
        return (vectors, pools)
    }

    private struct LocalPoint {
        let world: SIMD3<Float>
        let u: Float
        let v: Float
    }

    private struct Plane {
        let a: Float
        let b: Float
        let c: Float

        func y(u: Float, v: Float) -> Float { a * u + b * v + c }
    }

    private func analyze(
        points allPoints: [SIMD3<Float>],
        averageDepth: Double,
        meshCount: Int,
        cameraTransform: simd_float4x4,
        pointLimit: Int
    ) -> ScanMetrics? {
        guard allPoints.count >= 90 else { return nil }

        let analysisPoints: [SIMD3<Float>]
        if allPoints.count > pointLimit {
            let strideValue = max(1, allPoints.count / pointLimit)
            analysisPoints = Array(
                allPoints.enumerated().compactMap { index, point in
                    index % strideValue == 0 ? point : nil
                }.prefix(pointLimit)
            )
        } else {
            analysisPoints = allPoints
        }

        guard let surfaceBand = dominantHorizontalBand(points: analysisPoints), surfaceBand.count >= 80 else { return nil }

        var right = SIMD3<Float>(cameraTransform.columns.0.x, 0, cameraTransform.columns.0.z)
        var forward = SIMD3<Float>(-cameraTransform.columns.2.x, 0, -cameraTransform.columns.2.z)
        if simd_length(right) < 0.001 { right = SIMD3<Float>(1, 0, 0) }
        if simd_length(forward) < 0.001 { forward = SIMD3<Float>(0, 0, -1) }
        right = simd_normalize(right)
        forward = simd_normalize(forward)

        let origin = surfaceBand.reduce(SIMD3<Float>(repeating: 0), +) / Float(surfaceBand.count)
        var local = surfaceBand.map { point -> LocalPoint in
            let horizontal = SIMD3<Float>(point.x - origin.x, 0, point.z - origin.z)
            return LocalPoint(
                world: point,
                u: simd_dot(horizontal, right),
                v: simd_dot(horizontal, forward)
            )
        }

        guard let initialPlane = fitPlane(local), local.count >= 80 else { return nil }
        let residuals = local.map { Double($0.world.y - initialPlane.y(u: $0.u, v: $0.v)) }
        let medianResidual = median(residuals)
        let mad = median(residuals.map { abs($0 - medianResidual) })
        let residualLimit = Float(min(0.14, max(0.035, mad * 4.0 + 0.014)))
        local = local.filter { abs($0.world.y - initialPlane.y(u: $0.u, v: $0.v)) <= residualLimit }

        guard local.count >= 70, let plane = fitPlane(local) else { return nil }

        let uValues = local.map { Double($0.u) }
        let vValues = local.map { Double($0.v) }
        var uMin = Float(quantile(uValues, 0.02))
        var uMax = Float(quantile(uValues, 0.98))
        var vMin = Float(quantile(vValues, 0.02))
        var vMax = Float(quantile(vValues, 0.98))

        if uMax - uMin < 0.35 {
            let middle = (uMin + uMax) / 2
            uMin = middle - 0.175
            uMax = middle + 0.175
        }
        if vMax - vMin < 0.35 {
            let middle = (vMin + vMax) / 2
            vMin = middle - 0.175
            vMax = middle + 0.175
        }

        let columns = requestedColumns
        let rows = requestedRows
        let count = columns * rows
        var sums = Array(repeating: 0.0, count: count)
        var cellCounts = Array(repeating: 0, count: count)

        for point in local {
            guard point.u >= uMin, point.u <= uMax, point.v >= vMin, point.v <= vMax else { continue }
            let nx = Double((point.u - uMin) / max(uMax - uMin, 0.0001))
            let ny = Double((point.v - vMin) / max(vMax - vMin, 0.0001))
            let column = min(max(Int(round(nx * Double(columns - 1))), 0), columns - 1)
            let row = min(max(Int(round(ny * Double(rows - 1))), 0), rows - 1)
            let index = row * columns + column
            sums[index] += Double(point.world.y)
            cellCounts[index] += 1
        }

        let component = largestConnectedComponent(cellCounts: cellCounts, columns: columns, rows: rows)
        guard component.count >= 12 else { return nil }

        var heights = Array<Double?>(repeating: nil, count: count)
        for index in component where cellCounts[index] > 0 {
            heights[index] = sums[index] / Double(cellCounts[index])
        }

        let observedCount = component.count
        fillRowAndColumnGaps(&heights, columns: columns, rows: rows)
        interpolateSmallHoles(&heights, columns: columns, rows: rows, passes: 4)
        smoothGrid(&heights, columns: columns, rows: rows, passes: 2)

        let validHeights = heights.compactMap { $0 }
        guard validHeights.count >= 12 else { return nil }

        let robustMin = quantile(validHeights, 0.02)
        let robustMax = quantile(validHeights, 0.98)
        let meanHeight = validHeights.reduce(0, +) / Double(validHeights.count)
        let span = max(robustMax - robustMin, 0.002)

        var surfaceGrid = Array(repeating: -1.0, count: count)
        for index in heights.indices {
            if let value = heights[index] {
                let clamped = min(max(value, robustMin), robustMax)
                surfaceGrid[index] = min(max((clamped - robustMin) / span, 0), 1)
            }
        }

        let du = Double(uMax - uMin) / Double(max(columns - 1, 1))
        let dv = Double(vMax - vMin) / Double(max(rows - 1, 1))
        let localSlopeGrid = makeLocalSlopeGrid(
            heights: heights,
            columns: columns,
            rows: rows,
            du: du,
            dv: dv
        )

        var depressionGrid = Array(repeating: -1.0, count: count)
        var maximumDepression = 0.0
        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                guard let measuredY = heights[index] else { continue }
                let u = uMin + Float(column) / Float(max(columns - 1, 1)) * (uMax - uMin)
                let v = vMin + Float(row) / Float(max(rows - 1, 1)) * (vMax - vMin)
                let predicted = Double(plane.y(u: u, v: v))
                let depression = max(0, (predicted - measuredY) * 1000)
                depressionGrid[index] = depression
                maximumDepression = max(maximumDepression, depression)
            }
        }

        let validIndices = surfaceGrid.indices.filter { surfaceGrid[$0] >= 0 }
        guard let lowIndex = validIndices.min(by: { surfaceGrid[$0] < surfaceGrid[$1] }) else { return nil }
        let lowColumn = lowIndex % columns
        let lowRow = lowIndex / columns

        let gradient = sqrt(Double(plane.a * plane.a + plane.b * plane.b))
        let slopePercent = gradient * 100
        let slopeDegrees = atan(gradient) * 180 / .pi
        let downhillAngle = atan2(Double(-plane.a), Double(-plane.b))

        let coverage = Double(observedCount) / Double(count)
        let pointStrength = min(1, Double(allPoints.count) / Double(minimumRequiredPoints))
        let quality = min(1, coverage * 0.65 + pointStrength * 0.35)

        var result = ScanMetrics()
        result.slopePercent = slopePercent
        result.slopeDegrees = slopeDegrees
        result.distanceMeters = averageDepth
        result.quality = quality
        result.downhillAngleRadians = downhillAngle
        result.sampleCount = allPoints.count
        result.hasMeasurement = true
        result.surfaceGrid = surfaceGrid
        result.gridColumns = columns
        result.gridRows = rows
        result.lowPointX = Double(lowColumn) / Double(max(columns - 1, 1))
        result.lowPointY = Double(lowRow) / Double(max(rows - 1, 1))
        result.reliefMillimeters = span * 1000
        result.depressionMillimeters = maximumDepression
        result.flowPath = makeFlowPath(grid: surfaceGrid, columns: columns, rows: rows)
        result.coverage = coverage
        result.meshAnchorCount = meshCount
        result.minimumHeightMillimeters = (robustMin - meanHeight) * 1000
        result.maximumHeightMillimeters = (robustMax - meanHeight) * 1000
        result.localSlopeGrid = localSlopeGrid
        result.depressionGrid = depressionGrid
        return result
    }

    private func dominantHorizontalBand(points: [SIMD3<Float>]) -> [SIMD3<Float>]? {
        guard !points.isEmpty else { return nil }
        let binSize: Float = 0.05
        var histogram: [Int: Int] = [:]
        for point in points {
            let bin = Int(floor(point.y / binSize))
            histogram[bin, default: 0] += 1
        }
        guard let modeBin = histogram.max(by: { $0.value < $1.value })?.key else { return nil }
        let center = (Float(modeBin) + 0.5) * binSize

        var selected = points.filter { abs($0.y - center) <= 0.20 }
        if selected.count < 80 {
            let medianY = Float(median(points.map { Double($0.y) }))
            selected = points.filter { abs($0.y - medianY) <= 0.30 }
        }
        return selected
    }

    private func fitPlane(_ points: [LocalPoint]) -> Plane? {
        guard points.count >= 3 else { return nil }

        var suu = 0.0
        var suv = 0.0
        var su = 0.0
        var svv = 0.0
        var sv = 0.0
        var suy = 0.0
        var svy = 0.0
        var sy = 0.0

        for point in points {
            let u = Double(point.u)
            let v = Double(point.v)
            let y = Double(point.world.y)
            suu += u * u
            suv += u * v
            su += u
            svv += v * v
            sv += v
            suy += u * y
            svy += v * y
            sy += y
        }

        let n = Double(points.count)
        let determinant = det3(
            suu, suv, su,
            suv, svv, sv,
            su, sv, n
        )
        guard abs(determinant) > 1e-10 else { return nil }

        let detA = det3(
            suy, suv, su,
            svy, svv, sv,
            sy, sv, n
        )
        let detB = det3(
            suu, suy, su,
            suv, svy, sv,
            su, sy, n
        )
        let detC = det3(
            suu, suv, suy,
            suv, svv, svy,
            su, sv, sy
        )

        return Plane(
            a: Float(detA / determinant),
            b: Float(detB / determinant),
            c: Float(detC / determinant)
        )
    }

    private func det3(
        _ a: Double, _ b: Double, _ c: Double,
        _ d: Double, _ e: Double, _ f: Double,
        _ g: Double, _ h: Double, _ i: Double
    ) -> Double {
        a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
    }

    private func largestConnectedComponent(cellCounts: [Int], columns: Int, rows: Int) -> Set<Int> {
        var visited = Set<Int>()
        var best = Set<Int>()

        for start in cellCounts.indices where cellCounts[start] > 0 && !visited.contains(start) {
            var queue = [start]
            var head = 0
            var component = Set<Int>()
            visited.insert(start)

            while head < queue.count {
                let current = queue[head]
                head += 1
                component.insert(current)
                let row = current / columns
                let column = current % columns
                let neighbors = [(column - 1, row), (column + 1, row), (column, row - 1), (column, row + 1)]

                for (nc, nr) in neighbors {
                    guard nc >= 0, nc < columns, nr >= 0, nr < rows else { continue }
                    let next = nr * columns + nc
                    guard cellCounts[next] > 0, !visited.contains(next) else { continue }
                    visited.insert(next)
                    queue.append(next)
                }
            }

            if component.count > best.count { best = component }
        }
        return best
    }

    private func fillRowAndColumnGaps(_ heights: inout [Double?], columns: Int, rows: Int) {
        guard heights.count == columns * rows else { return }

        for row in 0..<rows {
            for column in 1..<(columns - 1) {
                let index = row * columns + column
                guard heights[index] == nil else { continue }
                for gap in 1...3 {
                    let left = column - gap
                    let right = column + gap
                    guard left >= 0, right < columns else { continue }
                    if let a = heights[row * columns + left], let b = heights[row * columns + right] {
                        heights[index] = (a + b) / 2
                        break
                    }
                }
            }
        }

        for column in 0..<columns {
            for row in 1..<(rows - 1) {
                let index = row * columns + column
                guard heights[index] == nil else { continue }
                for gap in 1...3 {
                    let top = row - gap
                    let bottom = row + gap
                    guard top >= 0, bottom < rows else { continue }
                    if let a = heights[top * columns + column], let b = heights[bottom * columns + column] {
                        heights[index] = (a + b) / 2
                        break
                    }
                }
            }
        }
    }

    private func interpolateSmallHoles(_ heights: inout [Double?], columns: Int, rows: Int, passes: Int) {
        guard heights.count == columns * rows else { return }
        for _ in 0..<passes {
            let source = heights
            var changed = false

            for row in 0..<rows {
                for column in 0..<columns {
                    let index = row * columns + column
                    guard source[index] == nil else { continue }
                    var neighbors: [Double] = []

                    for dr in -1...1 {
                        for dc in -1...1 where !(dc == 0 && dr == 0) {
                            let nr = row + dr
                            let nc = column + dc
                            guard nr >= 0, nr < rows, nc >= 0, nc < columns else { continue }
                            if let value = source[nr * columns + nc] { neighbors.append(value) }
                        }
                    }

                    if neighbors.count >= 4 {
                        heights[index] = neighbors.reduce(0, +) / Double(neighbors.count)
                        changed = true
                    }
                }
            }
            if !changed { break }
        }
    }

    private func smoothGrid(_ heights: inout [Double?], columns: Int, rows: Int, passes: Int) {
        guard heights.count == columns * rows else { return }
        for _ in 0..<passes {
            let source = heights
            for row in 0..<rows {
                for column in 0..<columns {
                    let index = row * columns + column
                    guard let center = source[index] else { continue }
                    var sum = center * 2
                    var weight = 2.0

                    for dr in -1...1 {
                        for dc in -1...1 where !(dc == 0 && dr == 0) {
                            let nr = row + dr
                            let nc = column + dc
                            guard nr >= 0, nr < rows, nc >= 0, nc < columns,
                                  let value = source[nr * columns + nc] else { continue }
                            sum += value
                            weight += 1
                        }
                    }
                    heights[index] = sum / weight
                }
            }
        }
    }

    private func makeLocalSlopeGrid(
        heights: [Double?],
        columns: Int,
        rows: Int,
        du: Double,
        dv: Double
    ) -> [Double] {
        var result = Array(repeating: -1.0, count: heights.count)
        guard du > 0.0001, dv > 0.0001 else { return result }

        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                guard heights[index] != nil else { continue }

                let left = column > 0 ? heights[row * columns + column - 1] : nil
                let right = column + 1 < columns ? heights[row * columns + column + 1] : nil
                let top = row > 0 ? heights[(row - 1) * columns + column] : nil
                let bottom = row + 1 < rows ? heights[(row + 1) * columns + column] : nil

                var dx = 0.0
                var dy = 0.0
                var hasX = false
                var hasY = false

                if let left, let right {
                    dx = (right - left) / (2 * du)
                    hasX = true
                }
                if let top, let bottom {
                    dy = (bottom - top) / (2 * dv)
                    hasY = true
                }

                if hasX || hasY {
                    result[index] = sqrt(dx * dx + dy * dy) * 100
                }
            }
        }
        return result
    }

    private func makeFlowPath(grid: [Double], columns: Int, rows: Int) -> [SurfacePoint] {
        let valid = grid.indices.filter { grid[$0] >= 0 }
        guard let start = valid.max(by: { grid[$0] < grid[$1] }) else { return [] }

        var current = start
        var visited = Set<Int>()
        var path: [SurfacePoint] = []

        for _ in 0..<max(columns, rows) * 2 {
            guard !visited.contains(current) else { break }
            visited.insert(current)
            let column = current % columns
            let row = current / columns
            path.append(
                SurfacePoint(
                    x: Double(column) / Double(max(columns - 1, 1)),
                    y: Double(row) / Double(max(rows - 1, 1))
                )
            )

            var next = current
            var bestHeight = grid[current]
            for dr in -1...1 {
                for dc in -1...1 where !(dc == 0 && dr == 0) {
                    let nr = row + dr
                    let nc = column + dc
                    guard nc >= 0, nc < columns, nr >= 0, nr < rows else { continue }
                    let candidate = nr * columns + nc
                    let value = grid[candidate]
                    guard value >= 0 else { continue }
                    if value < bestHeight - 0.002 {
                        bestHeight = value
                        next = candidate
                    }
                }
            }
            if next == current { break }
            current = next
        }
        return path
    }

    private func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    private func quantile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = min(max(q, 0), 1) * Double(sorted.count - 1)
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        if lower == upper { return sorted[lower] }
        let t = position - Double(lower)
        return sorted[lower] * (1 - t) + sorted[upper] * t
    }
}

struct ScannerCameraView: UIViewRepresentable {
    @ObservedObject var scanner: LiDARScanner

    func makeUIView(context: Context) -> LiveScannerContainerView {
        let view = LiveScannerContainerView()
        view.sceneView.session = scanner.session
        view.sceneView.scene = SCNScene()
        view.sceneView.backgroundColor = .black
        view.sceneView.automaticallyUpdatesLighting = false
        return view
    }

    func updateUIView(_ uiView: LiveScannerContainerView, context: Context) {
        uiView.sceneView.session = scanner.session
        uiView.sceneView.debugOptions = []
        uiView.flowOverlay.update(
            vectors: scanner.liveFlowVectors,
            pools: scanner.liveFlowPools,
            frame: scanner.session.currentFrame,
            measuring: scanner.isMeasuring
        )
    }
}

final class LiveScannerContainerView: UIView {
    let sceneView = ARSCNView(frame: .zero)
    let flowOverlay = LiveFlowOverlayView(frame: .zero)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        sceneView.translatesAutoresizingMaskIntoConstraints = false
        flowOverlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sceneView)
        addSubview(flowOverlay)

        NSLayoutConstraint.activate([
            sceneView.leadingAnchor.constraint(equalTo: leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: trailingAnchor),
            sceneView.topAnchor.constraint(equalTo: topAnchor),
            sceneView.bottomAnchor.constraint(equalTo: bottomAnchor),
            flowOverlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            flowOverlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            flowOverlay.topAnchor.constraint(equalTo: topAnchor),
            flowOverlay.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        flowOverlay.isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class LiveFlowOverlayView: UIView {
    private let flowColors: [UIColor] = [
        UIColor.systemBlue.withAlphaComponent(0.30),
        UIColor.cyan.withAlphaComponent(0.31),
        UIColor.systemGreen.withAlphaComponent(0.32),
        UIColor.systemYellow.withAlphaComponent(0.34),
        UIColor.systemOrange.withAlphaComponent(0.36)
    ]

    private var flowLayers: [CAShapeLayer] = []
    private let particleLayer = CAShapeLayer()
    private let arrowLayer = CAShapeLayer()
    private let poolLayer = CAShapeLayer()
    private let badge = UILabel()

    private var vectors: [LiveFlowVector] = []
    private var pools: [LiveFlowPool] = []
    private weak var currentFrame: ARFrame?
    private var measuring = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        for color in flowColors {
            let flow = CAShapeLayer()
            flow.fillColor = UIColor.clear.cgColor
            flow.strokeColor = color.cgColor
            flow.lineWidth = 13
            flow.lineCap = .round
            flow.lineJoin = .round
            flow.shadowColor = color.withAlphaComponent(0.75).cgColor
            flow.shadowRadius = 5
            flow.shadowOpacity = 0.55
            flow.shadowOffset = .zero
            layer.addSublayer(flow)
            flowLayers.append(flow)
        }

        particleLayer.fillColor = UIColor.clear.cgColor
        particleLayer.strokeColor = UIColor.white.withAlphaComponent(0.82).cgColor
        particleLayer.lineWidth = 2.1
        particleLayer.lineCap = .round
        particleLayer.lineJoin = .round
        particleLayer.lineDashPattern = [2, 10]
        particleLayer.shadowColor = UIColor.cyan.cgColor
        particleLayer.shadowRadius = 3
        particleLayer.shadowOpacity = 0.75
        particleLayer.shadowOffset = .zero
        layer.addSublayer(particleLayer)

        arrowLayer.fillColor = UIColor.clear.cgColor
        arrowLayer.strokeColor = UIColor.white.withAlphaComponent(0.76).cgColor
        arrowLayer.lineWidth = 1.5
        arrowLayer.lineCap = .round
        arrowLayer.lineJoin = .round
        layer.addSublayer(arrowLayer)

        poolLayer.fillColor = UIColor.systemRed.withAlphaComponent(0.18).cgColor
        poolLayer.strokeColor = UIColor.systemRed.withAlphaComponent(0.72).cgColor
        poolLayer.lineWidth = 1.6
        poolLayer.shadowColor = UIColor.systemRed.cgColor
        poolLayer.shadowRadius = 9
        poolLayer.shadowOpacity = 0.52
        poolLayer.shadowOffset = .zero
        layer.addSublayer(poolLayer)

        badge.text = "  DEFLUSSO LIVE  "
        badge.font = .systemFont(ofSize: 11, weight: .bold)
        badge.textColor = .white
        badge.backgroundColor = UIColor.black.withAlphaComponent(0.58)
        badge.layer.cornerRadius = 12
        badge.layer.masksToBounds = true
        badge.textAlignment = .center
        badge.isHidden = true
        addSubview(badge)

        let dash = CABasicAnimation(keyPath: "lineDashPhase")
        dash.fromValue = 0
        dash.toValue = -36
        dash.duration = 0.72
        dash.repeatCount = .infinity
        particleLayer.add(dash, forKey: "waterMotion")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for flow in flowLayers { flow.frame = bounds }
        particleLayer.frame = bounds
        arrowLayer.frame = bounds
        poolLayer.frame = bounds
        badge.frame = CGRect(x: 18, y: max(safeAreaInsets.top + 58, 78), width: 118, height: 25)
        redraw()
    }

    func update(vectors: [LiveFlowVector], pools: [LiveFlowPool], frame: ARFrame?, measuring: Bool) {
        self.vectors = vectors
        self.pools = pools
        currentFrame = frame
        self.measuring = measuring
        isHidden = !measuring
        badge.isHidden = !(measuring && (!vectors.isEmpty || !pools.isEmpty))
        redraw()
    }

    private func redraw() {
        guard measuring, bounds.width > 1, bounds.height > 1 else {
            clearPaths()
            return
        }

        var paths = flowLayers.map { _ in UIBezierPath() }
        let particles = UIBezierPath()
        let arrows = UIBezierPath()

        for (index, vector) in vectors.enumerated() {
            let start = mapImagePoint(vector.start)
            let end = mapImagePoint(vector.end)
            guard start.x.isFinite, start.y.isFinite, end.x.isFinite, end.y.isFinite else { continue }

            let bucket = min(flowLayers.count - 1, max(0, Int(floor(vector.intensity * Double(flowLayers.count)))))
            paths[bucket].move(to: start)
            paths[bucket].addLine(to: end)
            particles.move(to: start)
            particles.addLine(to: end)

            if index.isMultiple(of: 2) {
                addArrowHead(to: arrows, from: start, to: end, size: 5.5)
            }
        }

        for index in flowLayers.indices {
            flowLayers[index].path = paths[index].cgPath
        }
        particleLayer.path = particles.cgPath
        arrowLayer.path = arrows.cgPath

        let poolPath = UIBezierPath()
        for pool in pools {
            let center = mapImagePoint(pool.center)
            let radius = 10 + CGFloat(pool.strength) * 18
            poolPath.append(
                UIBezierPath(
                    ovalIn: CGRect(
                        x: center.x - radius,
                        y: center.y - radius,
                        width: radius * 2,
                        height: radius * 2
                    )
                )
            )
        }
        poolLayer.path = poolPath.cgPath
    }

    private func clearPaths() {
        for flow in flowLayers { flow.path = nil }
        particleLayer.path = nil
        arrowLayer.path = nil
        poolLayer.path = nil
    }

    private func mapImagePoint(_ point: CGPoint) -> CGPoint {
        var normalized = point
        if let frame = currentFrame {
            let orientation = window?.windowScene?.interfaceOrientation ?? .portrait
            let transform = frame.displayTransform(for: orientation, viewportSize: bounds.size)
            normalized = normalized.applying(transform)
        }
        return CGPoint(x: normalized.x * bounds.width, y: normalized.y * bounds.height)
    }

    private func addArrowHead(to path: UIBezierPath, from start: CGPoint, to end: CGPoint, size: CGFloat) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let left = CGPoint(
            x: end.x - size * cos(angle - .pi / 6),
            y: end.y - size * sin(angle - .pi / 6)
        )
        let right = CGPoint(
            x: end.x - size * cos(angle + .pi / 6),
            y: end.y - size * sin(angle + .pi / 6)
        )
        path.move(to: left)
        path.addLine(to: end)
        path.addLine(to: right)
    }
}