import ARKit
import AVFoundation
import Combine
import CoreVideo
import Foundation
import Metal
import SceneKit
import SwiftUI
import simd

final class LiDARScanner: NSObject, ObservableObject, ARSessionDelegate {
    let session = ARSession()

    @Published private(set) var metrics = ScanMetrics()
    @Published private(set) var isSupported = true
    @Published private(set) var isRunning = false
    @Published private(set) var isMeasuring = false
    @Published private(set) var cameraDenied = false
    @Published private(set) var supportsMeshReconstruction = false

    private var lastProcessedTimestamp: TimeInterval = 0
    private var accumulatedPoints: [SIMD3<Float>] = []
    private var accumulatedDepth: Double = 0
    private var accumulatedDepthCount = 0
    private var meshAnchorIDs: Set<UUID> = []
    private var lastCameraTransform = matrix_identity_float4x4

    private let requestedColumns = 25
    private let requestedRows = 19
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
        guard isMeasuring else { return metrics.hasMeasurement ? metrics : nil }
        let final = analyzeAccumulatedPoints(cameraTransform: lastCameraTransform)
        if let final {
            DispatchQueue.main.async { self.metrics = final }
        }
        DispatchQueue.main.async { self.isMeasuring = false }
        return final ?? (metrics.hasMeasurement ? metrics : nil)
    }

    func cancelMeasurement() {
        resetAcquisition()
        DispatchQueue.main.async {
            self.isMeasuring = false
            self.metrics = ScanMetrics()
        }
    }

    func pause() {
        session.pause()
        DispatchQueue.main.async {
            self.isRunning = false
            self.isMeasuring = false
        }
    }

    private func resetAcquisition() {
        lastProcessedTimestamp = 0
        accumulatedPoints.removeAll(keepingCapacity: true)
        accumulatedDepth = 0
        accumulatedDepthCount = 0
        meshAnchorIDs.removeAll(keepingCapacity: true)
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        updateMeshAnchors(anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        updateMeshAnchors(anchors)
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        for anchor in anchors where anchor is ARMeshAnchor {
            meshAnchorIDs.remove(anchor.identifier)
        }
    }

    private func updateMeshAnchors(_ anchors: [ARAnchor]) {
        for anchor in anchors where anchor is ARMeshAnchor {
            meshAnchorIDs.insert(anchor.identifier)
        }
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isRunning else { return }
        lastCameraTransform = frame.camera.transform
        guard isMeasuring else { return }
        guard frame.timestamp - lastProcessedTimestamp > 0.11 else { return }
        lastProcessedTimestamp = frame.timestamp

        guard let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }
        let collected = collectSamples(depthData: depthData, frame: frame)
        guard !collected.points.isEmpty else { return }

        accumulatedPoints.append(contentsOf: collected.points)
        accumulatedDepth += collected.depthSum
        accumulatedDepthCount += collected.depthCount

        if accumulatedPoints.count > maximumAccumulatedPoints {
            let excess = accumulatedPoints.count - maximumAccumulatedPoints
            accumulatedPoints.removeFirst(excess)
        }

        guard let result = analyzeAccumulatedPoints(cameraTransform: frame.camera.transform) else { return }
        DispatchQueue.main.async {
            self.metrics = result
        }
    }

    private struct CollectedFrame {
        var points: [SIMD3<Float>] = []
        var depthSum: Double = 0
        var depthCount = 0
    }

    private func collectSamples(depthData: ARDepthData, frame: ARFrame) -> CollectedFrame {
        let depthMap = depthData.depthMap
        let confidenceMap = depthData.confidenceMap

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        if let confidenceMap { CVPixelBufferLockBaseAddress(confidenceMap, .readOnly) }
        defer {
            CVPixelBufferUnlockBaseAddress(depthMap, .readOnly)
            if let confidenceMap { CVPixelBufferUnlockBaseAddress(confidenceMap, .readOnly) }
        }

        guard let depthBase = CVPixelBufferGetBaseAddress(depthMap) else { return CollectedFrame() }
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

        let xStart = Int(Float(depthWidth) * 0.10)
        let xEnd = Int(Float(depthWidth) * 0.90)
        let yStart = Int(Float(depthHeight) * 0.14)
        let yEnd = Int(Float(depthHeight) * 0.86)
        let xStep = max(1, (xEnd - xStart) / max(requestedColumns - 1, 1))
        let yStep = max(1, (yEnd - yStart) / max(requestedRows - 1, 1))

        var result = CollectedFrame()
        result.points.reserveCapacity(requestedColumns * requestedRows)

        for y in stride(from: yStart, through: yEnd, by: yStep).prefix(requestedRows) {
            for x in stride(from: xStart, through: xEnd, by: xStep).prefix(requestedColumns) {
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
                guard z.isFinite, z > 0.18, z < 5.0 else { continue }

                let cameraX = (Float(x) - cx) * z / fx
                let cameraY = -(Float(y) - cy) * z / fy
                let cameraPoint = SIMD4<Float>(cameraX, cameraY, -z, 1)
                let worldPoint4 = frame.camera.transform * cameraPoint
                result.points.append(SIMD3<Float>(worldPoint4.x, worldPoint4.y, worldPoint4.z))
                result.depthSum += Double(z)
                result.depthCount += 1
            }
        }

        return result
    }

    private func analyzeAccumulatedPoints(cameraTransform: simd_float4x4) -> ScanMetrics? {
        guard accumulatedPoints.count >= 80 else { return nil }

        let sortedY = accumulatedPoints.map(\.y).sorted()
        let medianY = sortedY[sortedY.count / 2]
        var points = accumulatedPoints.filter { abs($0.y - medianY) < 0.32 }
        guard points.count >= 60 else { return nil }

        if points.count > 12_000 {
            let step = max(1, points.count / 12_000)
            points = Array(points.enumerated().compactMap { index, point in
                index.isMultiple(of: step) ? point : nil
            }.prefix(12_000))
        }

        guard let plane = fitPlane(points) else { return nil }
        let a = plane.x
        let b = plane.y
        let c = plane.z

        let gradient = sqrt(a * a + b * b)
        let slopeDegrees = atan(gradient) * 180 / .pi
        let slopePercent = gradient * 100

        var downhill = SIMD3<Float>(-a, 0, -b)
        if simd_length(downhill) > 0.0001 {
            downhill = simd_normalize(downhill)
        }

        var right = SIMD3<Float>(cameraTransform.columns.0.x, 0, cameraTransform.columns.0.z)
        var forward = SIMD3<Float>(-cameraTransform.columns.2.x, 0, -cameraTransform.columns.2.z)
        if simd_length(right) > 0.001 { right = simd_normalize(right) }
        if simd_length(forward) > 0.001 { forward = simd_normalize(forward) }
        let downhillAngle = atan2(simd_dot(downhill, right), simd_dot(downhill, forward))

        guard let minX = points.map(\.x).min(),
              let maxX = points.map(\.x).max(),
              let minZ = points.map(\.z).min(),
              let maxZ = points.map(\.z).max() else { return nil }

        let spanX = max(maxX - minX, 0.08)
        let spanZ = max(maxZ - minZ, 0.08)
        let columns = requestedColumns
        let rows = requestedRows
        let cellCount = columns * rows

        var sums = Array(repeating: Float(0), count: cellCount)
        var counts = Array(repeating: 0, count: cellCount)
        var residualSums = Array(repeating: Float(0), count: cellCount)

        for point in points {
            let normalizedX = min(max((point.x - minX) / spanX, 0), 0.9999)
            let normalizedZ = min(max((point.z - minZ) / spanZ, 0), 0.9999)
            let column = min(columns - 1, Int(normalizedX * Float(columns)))
            let row = min(rows - 1, Int(normalizedZ * Float(rows)))
            let index = row * columns + column
            sums[index] += point.y
            counts[index] += 1
            let fittedY = a * point.x + b * point.z + c
            residualSums[index] += point.y - fittedY
        }

        var heights = Array(repeating: Double.nan, count: cellCount)
        var residuals = Array(repeating: Double.nan, count: cellCount)
        for index in 0..<cellCount where counts[index] > 0 {
            heights[index] = Double(sums[index] / Float(counts[index]))
            residuals[index] = Double(residualSums[index] / Float(counts[index]))
        }

        heights = fillSmallHoles(heights, columns: columns, rows: rows)
        residuals = fillSmallHoles(residuals, columns: columns, rows: rows)

        let validHeights = heights.filter(\.isFinite)
        guard validHeights.count >= 24,
              let minHeight = validHeights.min(),
              let maxHeight = validHeights.max() else { return nil }

        let heightSpan = max(maxHeight - minHeight, 0.0001)
        let meanHeight = validHeights.reduce(0, +) / Double(validHeights.count)
        let surfaceGrid = heights.map { value -> Double in
            guard value.isFinite else { return -1 }
            return min(max((value - minHeight) / heightSpan, 0), 1)
        }

        let validResiduals = residuals.filter(\.isFinite)
        let depressionGrid = residuals.map { value -> Double in
            guard value.isFinite else { return -1 }
            return max(0, -value * 1000)
        }
        let maxDepression = validResiduals.map { max(0, -$0 * 1000) }.max() ?? 0

        let localSlopeGrid = makeLocalSlopeGrid(
            heights: heights,
            columns: columns,
            rows: rows,
            cellWidth: Double(spanX) / Double(max(columns - 1, 1)),
            cellDepth: Double(spanZ) / Double(max(rows - 1, 1))
        )

        let validIndices = surfaceGrid.indices.filter { surfaceGrid[$0] >= 0 }
        guard let minimumIndex = validIndices.min(by: { surfaceGrid[$0] < surfaceGrid[$1] }) else { return nil }
        let lowColumn = minimumIndex % columns
        let lowRow = minimumIndex / columns
        let lowPointX = Double(lowColumn) / Double(max(columns - 1, 1))
        let lowPointY = Double(lowRow) / Double(max(rows - 1, 1))
        let flowPath = makeFlowPath(grid: surfaceGrid, columns: columns, rows: rows)

        let coverage = Double(validIndices.count) / Double(cellCount)
        let pointFactor = min(1, Double(points.count) / 7_000)
        let quality = min(1, coverage * 0.78 + pointFactor * 0.22)
        let averageDistance = accumulatedDepthCount > 0
            ? accumulatedDepth / Double(accumulatedDepthCount)
            : 0

        return ScanMetrics(
            slopePercent: Double(slopePercent),
            slopeDegrees: Double(slopeDegrees),
            distanceMeters: averageDistance,
            quality: quality,
            downhillAngleRadians: Double(downhillAngle),
            sampleCount: points.count,
            hasMeasurement: true,
            surfaceGrid: surfaceGrid,
            gridColumns: columns,
            gridRows: rows,
            lowPointX: lowPointX,
            lowPointY: lowPointY,
            reliefMillimeters: heightSpan * 1000,
            depressionMillimeters: maxDepression,
            flowPath: flowPath,
            coverage: coverage,
            meshAnchorCount: meshAnchorIDs.count,
            minimumHeightMillimeters: (minHeight - meanHeight) * 1000,
            maximumHeightMillimeters: (maxHeight - meanHeight) * 1000,
            localSlopeGrid: localSlopeGrid,
            depressionGrid: depressionGrid
        )
    }

    private func fitPlane(_ points: [SIMD3<Float>]) -> SIMD3<Float>? {
        var sxx: Float = 0
        var sxz: Float = 0
        var sx1: Float = 0
        var szz: Float = 0
        var sz1: Float = 0
        var sxy: Float = 0
        var szy: Float = 0
        var sy1: Float = 0

        for p in points {
            sxx += p.x * p.x
            sxz += p.x * p.z
            sx1 += p.x
            szz += p.z * p.z
            sz1 += p.z
            sxy += p.x * p.y
            szy += p.z * p.y
            sy1 += p.y
        }

        let n = Float(points.count)
        let matrix = simd_float3x3(
            SIMD3<Float>(sxx, sxz, sx1),
            SIMD3<Float>(sxz, szz, sz1),
            SIMD3<Float>(sx1, sz1, n)
        )
        guard abs(simd_determinant(matrix)) > 0.000001 else { return nil }
        return simd_inverse(matrix) * SIMD3<Float>(sxy, szy, sy1)
    }

    private func fillSmallHoles(_ values: [Double], columns: Int, rows: Int) -> [Double] {
        var result = values
        for _ in 0..<2 {
            var next = result
            for row in 0..<rows {
                for column in 0..<columns {
                    let index = row * columns + column
                    guard !result[index].isFinite else { continue }
                    var neighbors: [Double] = []
                    for rowOffset in -1...1 {
                        for columnOffset in -1...1 where !(rowOffset == 0 && columnOffset == 0) {
                            let r = row + rowOffset
                            let c = column + columnOffset
                            guard r >= 0, r < rows, c >= 0, c < columns else { continue }
                            let value = result[r * columns + c]
                            if value.isFinite { neighbors.append(value) }
                        }
                    }
                    if neighbors.count >= 4 {
                        next[index] = neighbors.reduce(0, +) / Double(neighbors.count)
                    }
                }
            }
            result = next
        }
        return result
    }

    private func makeLocalSlopeGrid(
        heights: [Double],
        columns: Int,
        rows: Int,
        cellWidth: Double,
        cellDepth: Double
    ) -> [Double] {
        var result = Array(repeating: -1.0, count: heights.count)
        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                guard heights[index].isFinite else { continue }

                let left = heights[row * columns + max(column - 1, 0)]
                let right = heights[row * columns + min(column + 1, columns - 1)]
                let up = heights[max(row - 1, 0) * columns + column]
                let down = heights[min(row + 1, rows - 1) * columns + column]
                guard left.isFinite, right.isFinite, up.isFinite, down.isFinite else { continue }

                let dxDivisor = cellWidth * Double(column == 0 || column == columns - 1 ? 1 : 2)
                let dzDivisor = cellDepth * Double(row == 0 || row == rows - 1 ? 1 : 2)
                let dx = (right - left) / max(dxDivisor, 0.001)
                let dz = (down - up) / max(dzDivisor, 0.001)
                result[index] = sqrt(dx * dx + dz * dz) * 100
            }
        }
        return result
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

        for _ in 0..<64 {
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
                    if candidateHeight < bestHeight - 0.0015 {
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

    func makeCoordinator() -> Coordinator {
        Coordinator(scanner: scanner)
    }

    func makeUIView(context: Context) -> ARSCNView {
        let view = ARSCNView(frame: .zero)
        view.session = scanner.session
        view.scene = SCNScene()
        view.delegate = context.coordinator
        view.backgroundColor = .black
        view.automaticallyUpdatesLighting = true
        view.preferredFramesPerSecond = 60
        return view
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        context.coordinator.scanner = scanner
        uiView.scene.rootNode.enumerateChildNodes { node, _ in
            if node.name == Coordinator.meshNodeName {
                node.isHidden = !scanner.isMeasuring
            }
        }
    }

    final class Coordinator: NSObject, ARSCNViewDelegate {
        static let meshNodeName = "drainmap.mesh"
        var scanner: LiDARScanner

        init(scanner: LiDARScanner) {
            self.scanner = scanner
        }

        func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
            guard let meshAnchor = anchor as? ARMeshAnchor else { return nil }
            let node = SCNNode(geometry: makeGeometry(from: meshAnchor.geometry))
            node.name = Self.meshNodeName
            node.isHidden = !scanner.isMeasuring
            return node
        }

        func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
            guard let meshAnchor = anchor as? ARMeshAnchor else { return }
            node.geometry = makeGeometry(from: meshAnchor.geometry)
            node.name = Self.meshNodeName
            node.isHidden = !scanner.isMeasuring
        }

        private func makeGeometry(from mesh: ARMeshGeometry) -> SCNGeometry {
            let vertices = mesh.vertices
            let source = SCNGeometrySource(
                buffer: vertices.buffer,
                vertexFormat: vertices.format,
                semantic: .vertex,
                vertexCount: vertices.count,
                dataOffset: vertices.offset,
                dataStride: vertices.stride
            )

            let faces = mesh.faces
            let faceData = Data(
                bytesNoCopy: faces.buffer.contents(),
                count: faces.buffer.length,
                deallocator: .none
            )
            let element = SCNGeometryElement(
                data: faceData,
                primitiveType: .triangles,
                primitiveCount: faces.count,
                bytesPerIndex: faces.bytesPerIndex
            )

            let geometry = SCNGeometry(sources: [source], elements: [element])
            let material = SCNMaterial()
            material.lightingModel = .constant
            material.diffuse.contents = UIColor.systemCyan.withAlphaComponent(0.70)
            material.emission.contents = UIColor.systemCyan.withAlphaComponent(0.16)
            material.fillMode = .lines
            material.isDoubleSided = true
            geometry.materials = [material]
            return geometry
        }
    }
}
