import ARKit
import AVFoundation
import Combine
import CoreVideo
import Foundation
import SceneKit
import SwiftUI
import UIKit
import simd

final class LiDARScanner: NSObject, ObservableObject, ARSessionDelegate {
    let session = ARSession()

    @Published private(set) var metrics = ScanMetrics()
    @Published private(set) var isSupported = true
    @Published private(set) var isRunning = false
    @Published private(set) var isMeasuring = false
    @Published private(set) var cameraDenied = false
    @Published private(set) var supportsMeshReconstruction = false

    private let stateLock = NSLock()
    private var lastProcessedTimestamp: TimeInterval = 0
    private var accumulatedPoints: [SIMD3<Float>] = []
    private var accumulatedDepth: Double = 0
    private var accumulatedDepthCount = 0
    private var meshAnchorIDs: Set<UUID> = []
    private var lastCameraTransform = matrix_identity_float4x4

    private let requestedColumns = 21
    private let requestedRows = 15
    private let maximumAccumulatedPoints = 18_000

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
        }
    }

    func beginMeasurement() {
        guard isRunning else { return }
        resetAcquisition()
        DispatchQueue.main.async {
            self.metrics = ScanMetrics()
            self.isMeasuring = true
        }
    }

    @discardableResult
    func finishMeasurement() -> ScanMetrics? {
        let snapshot = acquisitionSnapshot()
        let final = analyze(points: snapshot.points,
                            averageDepth: snapshot.averageDepth,
                            meshCount: snapshot.meshCount,
                            cameraTransform: snapshot.cameraTransform)

        DispatchQueue.main.async {
            self.isMeasuring = false
            if let final { self.metrics = final }
        }
        return final ?? (metrics.hasMeasurement ? metrics : nil)
    }

    func cancelMeasurement() {
        resetAcquisition()
        DispatchQueue.main.async {
            self.metrics = ScanMetrics()
            self.isMeasuring = false
        }
    }

    func pause() {
        session.pause()
        DispatchQueue.main.async {
            self.isRunning = false
            self.isMeasuring = false
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
        if shouldMeasure && elapsed > 0.14 {
            lastProcessedTimestamp = frame.timestamp
        }
        stateLock.unlock()

        guard shouldMeasure, elapsed > 0.14 else { return }
        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }

        let batch = extractPoints(depthData: depthData, frame: frame)
        guard !batch.points.isEmpty else { return }

        stateLock.lock()
        accumulatedPoints.append(contentsOf: batch.points)
        accumulatedDepth += batch.depthSum
        accumulatedDepthCount += batch.depthCount
        if accumulatedPoints.count > maximumAccumulatedPoints {
            accumulatedPoints.removeFirst(accumulatedPoints.count - maximumAccumulatedPoints)
        }
        let points = accumulatedPoints
        let averageDepth = accumulatedDepthCount > 0 ? accumulatedDepth / Double(accumulatedDepthCount) : 0
        let meshCount = meshAnchorIDs.count
        let cameraTransform = lastCameraTransform
        stateLock.unlock()

        guard let live = analyze(points: points,
                                 averageDepth: averageDepth,
                                 meshCount: meshCount,
                                 cameraTransform: cameraTransform) else { return }

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

    private struct PointBatch {
        var points: [SIMD3<Float>]
        var depthSum: Double
        var depthCount: Int
    }

    private func extractPoints(depthData: ARDepthData, frame: ARFrame) -> PointBatch {
        let depthMap = depthData.depthMap
        let confidenceMap = depthData.confidenceMap

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        if let confidenceMap { CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
        }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else {
            return PointBatch(points: [], depthSum: 0, depthCount: 0)
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
        let xStep = max(1, (xEnd - xStart) / max(sampleColumns - 1, 1))
        let yStep = max(1, (yEnd - yStart) / max(sampleRows - 1, 1))

        var points: [SIMD3<Float>] = []
        points.reserveCapacity(sampleColumns * sampleRows)
        var depthSum = 0.0
        var depthCount = 0

        for y in stride(from: yStart, through: yEnd, by: yStep) {
            for x in stride(from: xStart, through: xEnd, by: xStep) {
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
                points.append(SIMD3<Float>(worldPoint4.x, worldPoint4.y, worldPoint4.z))
                depthSum += Double(z)
                depthCount += 1
            }
        }

        return PointBatch(points: points, depthSum: depthSum, depthCount: depthCount)
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

    private func analyze(points allPoints: [SIMD3<Float>],
                         averageDepth: Double,
                         meshCount: Int,
                         cameraTransform: simd_float4x4) -> ScanMetrics? {
        guard allPoints.count >= 90 else { return nil }

        let analysisPoints: [SIMD3<Float>]
        if allPoints.count > 10_000 {
            let strideValue = max(1, allPoints.count / 10_000)
            analysisPoints = Array(allPoints.enumerated().compactMap { index, point in
                index % strideValue == 0 ? point : nil
            }.prefix(10_000))
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
            return LocalPoint(world: point, u: simd_dot(horizontal, right), v: simd_dot(horizontal, forward))
        }

        guard let initialPlane = fitPlane(local), local.count >= 80 else { return nil }
        let residuals = local.map { Double($0.world.y - initialPlane.y(u: $0.u, v: $0.v)) }
        let medianResidual = median(residuals)
        let deviations = residuals.map { abs($0 - medianResidual) }
        let mad = median(deviations)
        let residualLimit = Float(min(0.16, max(0.045, mad * 4.0 + 0.018)))
        local = local.filter { abs($0.world.y - initialPlane.y(u: $0.u, v: $0.v)) <= residualLimit }

        guard local.count >= 70, let plane = fitPlane(local) else { return nil }

        let uValues = local.map { Double($0.u) }
        let vValues = local.map { Double($0.v) }
        var uMin = Float(quantile(uValues, 0.02))
        var uMax = Float(quantile(uValues, 0.98))
        var vMin = Float(quantile(vValues, 0.02))
        var vMax = Float(quantile(vValues, 0.98))

        if uMax - uMin < 0.35 {
            let mid = (uMin + uMax) / 2
            uMin = mid - 0.175
            uMax = mid + 0.175
        }
        if vMax - vMin < 0.35 {
            let mid = (vMin + vMax) / 2
            vMin = mid - 0.175
            vMax = mid + 0.175
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
        let localSlopeGrid = makeLocalSlopeGrid(heights: heights, columns: columns, rows: rows, du: du, dv: dv)

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
        let sampleStrength = min(1, Double(local.count) / 5000.0)
        let quality = min(1, coverage * 0.72 + sampleStrength * 0.28)

        var result = ScanMetrics()
        result.slopePercent = slopePercent
        result.slopeDegrees = slopeDegrees
        result.distanceMeters = averageDepth
        result.quality = quality
        result.downhillAngleRadians = downhillAngle
        result.sampleCount = local.count
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

        var selected = points.filter { abs($0.y - center) <= 0.22 }
        if selected.count < 80 {
            let medianY = Float(median(points.map { Double($0.y) }))
            selected = points.filter { abs($0.y - medianY) <= 0.32 }
        }
        return selected
    }

    private func fitPlane(_ points: [LocalPoint]) -> Plane? {
        guard points.count >= 3 else { return nil }
        var suu: Float = 0
        var suv: Float = 0
        var su1: Float = 0
        var svv: Float = 0
        var sv1: Float = 0
        var suy: Float = 0
        var svy: Float = 0
        var sy1: Float = 0

        for point in points {
            let u = point.u
            let v = point.v
            let y = point.world.y
            suu += u * u
            suv += u * v
            su1 += u
            svv += v * v
            sv1 += v
            suy += u * y
            svy += v * y
            sy1 += y
        }

        let n = Float(points.count)
        let matrix = simd_float3x3(
            SIMD3<Float>(suu, suv, su1),
            SIMD3<Float>(suv, svv, sv1),
            SIMD3<Float>(su1, sv1, n)
        )
        guard abs(simd_determinant(matrix)) > 0.000001 else { return nil }
        let coefficients = simd_inverse(matrix) * SIMD3<Float>(suy, svy, sy1)
        return Plane(a: coefficients.x, b: coefficients.y, c: coefficients.z)
    }

    private func largestConnectedComponent(cellCounts: [Int], columns: Int, rows: Int) -> Set<Int> {
        let valid = Set(cellCounts.indices.filter { cellCounts[$0] > 0 })
        var remaining = valid
        var largest: Set<Int> = []
        let neighbors = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]

        while let start = remaining.first {
            var queue = [start]
            var component: Set<Int> = []
            remaining.remove(start)

            while !queue.isEmpty {
                let current = queue.removeLast()
                component.insert(current)
                let column = current % columns
                let row = current / columns

                for (dc, dr) in neighbors {
                    let nc = column + dc
                    let nr = row + dr
                    guard nc >= 0, nc < columns, nr >= 0, nr < rows else { continue }
                    let next = nr * columns + nc
                    if remaining.remove(next) != nil {
                        queue.append(next)
                    }
                }
            }

            if component.count > largest.count { largest = component }
        }
        return largest
    }

    private func fillRowAndColumnGaps(_ grid: inout [Double?], columns: Int, rows: Int) {
        for row in 0..<rows {
            let validColumns = (0..<columns).filter { grid[row * columns + $0] != nil }
            guard let first = validColumns.first, let last = validColumns.last, last > first else { continue }
            for column in (first + 1)..<last where grid[row * columns + column] == nil {
                let left = stride(from: column - 1, through: first, by: -1).first { grid[row * columns + $0] != nil }
                let right = ((column + 1)...last).first { grid[row * columns + $0] != nil }
                if let left, let right,
                   let lv = grid[row * columns + left], let rv = grid[row * columns + right] {
                    let t = Double(column - left) / Double(right - left)
                    grid[row * columns + column] = lv * (1 - t) + rv * t
                }
            }
        }

        for column in 0..<columns {
            let validRows = (0..<rows).filter { grid[$0 * columns + column] != nil }
            guard let first = validRows.first, let last = validRows.last, last > first else { continue }
            for row in (first + 1)..<last where grid[row * columns + column] == nil {
                let top = stride(from: row - 1, through: first, by: -1).first { grid[$0 * columns + column] != nil }
                let bottom = ((row + 1)...last).first { grid[$0 * columns + column] != nil }
                if let top, let bottom,
                   let tv = grid[top * columns + column], let bv = grid[bottom * columns + column] {
                    let t = Double(row - top) / Double(bottom - top)
                    grid[row * columns + column] = tv * (1 - t) + bv * t
                }
            }
        }
    }

    private func interpolateSmallHoles(_ grid: inout [Double?], columns: Int, rows: Int, passes: Int) {
        guard passes > 0 else { return }
        for _ in 0..<passes {
            var next = grid
            for row in 0..<rows {
                for column in 0..<columns {
                    let index = row * columns + column
                    guard grid[index] == nil else { continue }
                    var values: [Double] = []
                    for dr in -1...1 {
                        for dc in -1...1 where !(dc == 0 && dr == 0) {
                            let nc = column + dc
                            let nr = row + dr
                            guard nc >= 0, nc < columns, nr >= 0, nr < rows else { continue }
                            if let value = grid[nr * columns + nc] { values.append(value) }
                        }
                    }
                    if values.count >= 4 {
                        next[index] = values.reduce(0, +) / Double(values.count)
                    }
                }
            }
            grid = next
        }
    }

    private func smoothGrid(_ grid: inout [Double?], columns: Int, rows: Int, passes: Int) {
        for _ in 0..<passes {
            var next = grid
            for row in 0..<rows {
                for column in 0..<columns {
                    let index = row * columns + column
                    guard let center = grid[index] else { continue }
                    var sum = center * 2.0
                    var weight = 2.0
                    for (dc, dr) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                        let nc = column + dc
                        let nr = row + dr
                        guard nc >= 0, nc < columns, nr >= 0, nr < rows,
                              let value = grid[nr * columns + nc] else { continue }
                        sum += value
                        weight += 1
                    }
                    next[index] = sum / weight
                }
            }
            grid = next
        }
    }

    private func makeLocalSlopeGrid(heights: [Double?], columns: Int, rows: Int, du: Double, dv: Double) -> [Double] {
        var result = Array(repeating: -1.0, count: heights.count)
        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                guard heights[index] != nil else { continue }

                let left = column > 0 ? heights[row * columns + column - 1] : nil
                let right = column + 1 < columns ? heights[row * columns + column + 1] : nil
                let top = row > 0 ? heights[(row - 1) * columns + column] : nil
                let bottom = row + 1 < rows ? heights[(row + 1) * columns + column] : nil

                let dx: Double
                if let left, let right { dx = (right - left) / max(2 * du, 0.001) }
                else if let center = heights[index], let right { dx = (right - center) / max(du, 0.001) }
                else if let center = heights[index], let left { dx = (center - left) / max(du, 0.001) }
                else { dx = 0 }

                let dy: Double
                if let top, let bottom { dy = (bottom - top) / max(2 * dv, 0.001) }
                else if let center = heights[index], let bottom { dy = (bottom - center) / max(dv, 0.001) }
                else if let center = heights[index], let top { dy = (center - top) / max(dv, 0.001) }
                else { dy = 0 }

                result[index] = sqrt(dx * dx + dy * dy) * 100
            }
        }
        return result
    }

    private func makeFlowPath(grid: [Double], columns: Int, rows: Int) -> [SurfacePoint] {
        guard columns > 1, rows > 1, grid.count == columns * rows else { return [] }
        let validIndices = grid.indices.filter { grid[$0] >= 0 }
        guard !validIndices.isEmpty else { return [] }

        let centerColumn = columns / 2
        let centerRow = rows / 2
        let start = validIndices.min { lhs, rhs in
            let lc = lhs % columns
            let lr = lhs / columns
            let rc = rhs % columns
            let rr = rhs / columns
            let ld = (lc - centerColumn) * (lc - centerColumn) + (lr - centerRow) * (lr - centerRow)
            let rd = (rc - centerColumn) * (rc - centerColumn) + (rr - centerRow) * (rr - centerRow)
            return ld < rd
        } ?? validIndices[0]

        var current = start
        var visited: Set<Int> = []
        var path: [SurfacePoint] = []

        for _ in 0..<36 {
            if visited.contains(current) { break }
            visited.insert(current)
            let column = current % columns
            let row = current / columns
            path.append(SurfacePoint(
                x: Double(column) / Double(columns - 1),
                y: Double(row) / Double(rows - 1)
            ))

            let currentHeight = grid[current]
            var next = current
            var bestHeight = currentHeight
            for dr in -1...1 {
                for dc in -1...1 where !(dc == 0 && dr == 0) {
                    let nc = column + dc
                    let nr = row + dr
                    guard nc >= 0, nc < columns, nr >= 0, nr < rows else { continue }
                    let candidate = nr * columns + nc
                    let value = grid[candidate]
                    guard value >= 0 else { continue }
                    if value < bestHeight - 0.0025 {
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
        let mid = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[mid - 1] + sorted[mid]) / 2
        }
        return sorted[mid]
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
        if scanner.supportsMeshReconstruction && scanner.isMeasuring {
            uiView.sceneView.debugOptions = [.showSceneUnderstanding]
        } else {
            uiView.sceneView.debugOptions = []
        }
        uiView.flowOverlay.update(metrics: scanner.metrics,
                                  frame: scanner.session.currentFrame,
                                  measuring: scanner.isMeasuring)
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
    private let streamLayer = CAShapeLayer()
    private let arrowLayer = CAShapeLayer()
    private let primaryLayer = CAShapeLayer()
    private let lowPointLayer = CAShapeLayer()
    private let badge = UILabel()

    private var currentMetrics = ScanMetrics()
    private weak var currentFrame: ARFrame?
    private var measuring = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear

        streamLayer.fillColor = UIColor.clear.cgColor
        streamLayer.strokeColor = UIColor.cyan.withAlphaComponent(0.72).cgColor
        streamLayer.lineWidth = 1.7
        streamLayer.lineCap = .round
        streamLayer.lineJoin = .round
        streamLayer.lineDashPattern = [6, 7]

        arrowLayer.fillColor = UIColor.clear.cgColor
        arrowLayer.strokeColor = UIColor.cyan.withAlphaComponent(0.88).cgColor
        arrowLayer.lineWidth = 1.7
        arrowLayer.lineCap = .round
        arrowLayer.lineJoin = .round

        primaryLayer.fillColor = UIColor.clear.cgColor
        primaryLayer.strokeColor = UIColor.white.withAlphaComponent(0.95).cgColor
        primaryLayer.lineWidth = 3.0
        primaryLayer.lineCap = .round
        primaryLayer.lineJoin = .round
        primaryLayer.lineDashPattern = [9, 7]
        primaryLayer.shadowColor = UIColor.cyan.cgColor
        primaryLayer.shadowRadius = 5
        primaryLayer.shadowOpacity = 0.8
        primaryLayer.shadowOffset = .zero

        lowPointLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.25).cgColor
        lowPointLayer.strokeColor = UIColor.white.cgColor
        lowPointLayer.lineWidth = 2
        lowPointLayer.shadowColor = UIColor.cyan.cgColor
        lowPointLayer.shadowRadius = 6
        lowPointLayer.shadowOpacity = 0.8
        lowPointLayer.shadowOffset = .zero

        layer.addSublayer(streamLayer)
        layer.addSublayer(arrowLayer)
        layer.addSublayer(primaryLayer)
        layer.addSublayer(lowPointLayer)

        badge.text = "  FLUSSO LIVE  "
        badge.font = .systemFont(ofSize: 11, weight: .bold)
        badge.textColor = .white
        badge.backgroundColor = UIColor.black.withAlphaComponent(0.58)
        badge.layer.cornerRadius = 11
        badge.layer.masksToBounds = true
        badge.textAlignment = .center
        badge.isHidden = true
        addSubview(badge)

        let dash = CABasicAnimation(keyPath: "lineDashPhase")
        dash.fromValue = 0
        dash.toValue = -26
        dash.duration = 0.9
        dash.repeatCount = .infinity
        streamLayer.add(dash, forKey: "flowDash")

        let primaryDash = CABasicAnimation(keyPath: "lineDashPhase")
        primaryDash.fromValue = 0
        primaryDash.toValue = -32
        primaryDash.duration = 0.75
        primaryDash.repeatCount = .infinity
        primaryLayer.add(primaryDash, forKey: "primaryFlowDash")
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        streamLayer.frame = bounds
        arrowLayer.frame = bounds
        primaryLayer.frame = bounds
        lowPointLayer.frame = bounds
        badge.frame = CGRect(x: 18, y: max(safeAreaInsets.top + 58, 78), width: 92, height: 23)
        redraw()
    }

    func update(metrics: ScanMetrics, frame: ARFrame?, measuring: Bool) {
        currentMetrics = metrics
        currentFrame = frame
        self.measuring = measuring
        badge.isHidden = !(measuring && metrics.hasMeasurement)
        isHidden = !measuring
        redraw()
    }

    private func redraw() {
        guard measuring,
              currentMetrics.hasMeasurement,
              currentMetrics.gridColumns > 1,
              currentMetrics.gridRows > 1,
              currentMetrics.surfaceGrid.count == currentMetrics.gridColumns * currentMetrics.gridRows,
              bounds.width > 1,
              bounds.height > 1 else {
            streamLayer.path = nil
            arrowLayer.path = nil
            primaryLayer.path = nil
            lowPointLayer.path = nil
            return
        }

        let metrics = currentMetrics
        let columns = metrics.gridColumns
        let rows = metrics.gridRows
        let streamPath = UIBezierPath()
        let arrows = UIBezierPath()

        let stepColumn = max(2, columns / 7)
        let stepRow = max(2, rows / 5)

        for row in stride(from: 1, to: rows - 1, by: stepRow) {
            for column in stride(from: 1, to: columns - 1, by: stepColumn) {
                let index = row * columns + column
                let current = metrics.surfaceGrid[index]
                guard current >= 0 else { continue }

                var bestColumn = column
                var bestRow = row
                var bestValue = current
                for dr in -1...1 {
                    for dc in -1...1 where !(dc == 0 && dr == 0) {
                        let nc = column + dc
                        let nr = row + dr
                        let candidate = nr * columns + nc
                        let value = metrics.surfaceGrid[candidate]
                        guard value >= 0 else { continue }
                        if value < bestValue - 0.006 {
                            bestValue = value
                            bestColumn = nc
                            bestRow = nr
                        }
                    }
                }

                guard bestColumn != column || bestRow != row else { continue }
                let start = mapGridPoint(column: column, row: row, columns: columns, rows: rows)
                let neighbor = mapGridPoint(column: bestColumn, row: bestRow, columns: columns, rows: rows)
                let dx = neighbor.x - start.x
                let dy = neighbor.y - start.y
                let length = max(hypot(dx, dy), 0.001)
                let scale: CGFloat = 1.75
                let end = CGPoint(x: start.x + dx / length * min(length * scale, 48),
                                  y: start.y + dy / length * min(length * scale, 48))
                streamPath.move(to: start)
                streamPath.addLine(to: end)
                addArrowHead(to: arrows, from: start, to: end, size: 6.5)
            }
        }

        streamLayer.path = streamPath.cgPath
        arrowLayer.path = arrows.cgPath

        let primary = UIBezierPath()
        if metrics.flowPath.count > 1 {
            for (offset, point) in metrics.flowPath.enumerated() {
                let mapped = mapNormalizedGridPoint(point)
                if offset == 0 { primary.move(to: mapped) }
                else { primary.addLine(to: mapped) }
            }
        }
        primaryLayer.path = primary.cgPath

        let low = mapNormalizedGridPoint(SurfacePoint(x: metrics.lowPointX, y: metrics.lowPointY))
        lowPointLayer.path = UIBezierPath(ovalIn: CGRect(x: low.x - 9, y: low.y - 9, width: 18, height: 18)).cgPath
    }

    private func addArrowHead(to path: UIBezierPath, from start: CGPoint, to end: CGPoint, size: CGFloat) {
        let angle = atan2(end.y - start.y, end.x - start.x)
        let left = CGPoint(x: end.x - size * cos(angle - .pi / 6),
                           y: end.y - size * sin(angle - .pi / 6))
        let right = CGPoint(x: end.x - size * cos(angle + .pi / 6),
                            y: end.y - size * sin(angle + .pi / 6))
        path.move(to: left)
        path.addLine(to: end)
        path.addLine(to: right)
    }

    private func mapNormalizedGridPoint(_ point: SurfacePoint) -> CGPoint {
        let columns = max(currentMetrics.gridColumns, 2)
        let rows = max(currentMetrics.gridRows, 2)
        let column = Int(round(point.x * Double(columns - 1)))
        let row = Int(round(point.y * Double(rows - 1)))
        return mapGridPoint(column: column, row: row, columns: columns, rows: rows)
    }

    private func mapGridPoint(column: Int, row: Int, columns: Int, rows: Int) -> CGPoint {
        let gx = CGFloat(column) / CGFloat(max(columns - 1, 1))
        let gy = CGFloat(row) / CGFloat(max(rows - 1, 1))

        var normalized = CGPoint(
            x: 0.10 + gx * 0.80,
            y: 0.16 + gy * 0.68
        )

        if let frame = currentFrame {
            let orientation = window?.windowScene?.interfaceOrientation ?? .portrait
            let transform = frame.displayTransform(for: orientation, viewportSize: bounds.size)
            normalized = normalized.applying(transform)
        }

        return CGPoint(x: normalized.x * bounds.width, y: normalized.y * bounds.height)
    }
}
