import ARKit
import AVFoundation
import CoreVideo
import Foundation
import simd

final class LiDARAcquisitionEngine: NSObject, ARSessionDelegate {
    struct Snapshot {
        let points: [SIMD3<Float>]
        let averageDepth: Double
        let meshAnchorCount: Int
        let cameraTransform: simd_float4x4
        let pointCount: Int
    }

    let session = ARSession()
    let maximumStoredPoints: Int

    var onPointCountChanged: ((Int) -> Void)?
    var onStatusChanged: ((Bool, Bool, Bool, Bool) -> Void)?
    var onFrameProcessed: (() -> Void)?

    private let lock = NSLock()
    private var points: [SIMD3<Float>] = []
    private var writeIndex = 0
    private var depthSum = 0.0
    private var depthCount = 0
    private var meshAnchorIDs: Set<UUID> = []
    private var lastCameraTransform = matrix_identity_float4x4
    private var lastProcessedTimestamp: TimeInterval = 0
    private var measuring = false
    private var running = false
    private var meshSupported = false
    private let frameInterval: TimeInterval = 0.10

    init(maximumStoredPoints: Int = 50_000) {
        self.maximumStoredPoints = max(maximumStoredPoints, 40_000)
        super.init()
        session.delegate = self
    }

    func start() {
        guard ARWorldTrackingConfiguration.isSupported,
              ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) else {
            publishStatus(supported: false, running: false, measuring: false, cameraDenied: false)
            return
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                guard let self else { return }
                if granted {
                    self.startSession()
                } else {
                    self.publishStatus(supported: true, running: false, measuring: false, cameraDenied: true)
                }
            }
        case .denied, .restricted:
            publishStatus(supported: true, running: false, measuring: false, cameraDenied: true)
        @unknown default:
            publishStatus(supported: true, running: false, measuring: false, cameraDenied: true)
        }
    }

    func beginMeasurement() {
        lock.lock()
        resetLocked()
        measuring = true
        let isRunning = running
        lock.unlock()
        onPointCountChanged?(0)
        publishStatus(supported: true, running: isRunning, measuring: true, cameraDenied: false)
    }

    func cancelMeasurement() {
        lock.lock()
        resetLocked()
        measuring = false
        let isRunning = running
        lock.unlock()
        onPointCountChanged?(0)
        publishStatus(supported: true, running: isRunning, measuring: false, cameraDenied: false)
    }

    func pause() {
        session.pause()
        lock.lock()
        running = false
        measuring = false
        lock.unlock()
        publishStatus(supported: true, running: false, measuring: false, cameraDenied: false)
    }

    func stopMeasuringPreservingData() {
        lock.lock()
        measuring = false
        let isRunning = running
        lock.unlock()
        publishStatus(supported: true, running: isRunning, measuring: false, cameraDenied: false)
    }

    func snapshot(limit: Int? = nil) -> Snapshot {
        lock.lock()
        let stored = points
        let average = depthCount > 0 ? depthSum / Double(depthCount) : 0
        let anchors = meshAnchorIDs.count
        let transform = lastCameraTransform
        let count = points.count
        lock.unlock()

        let resultPoints: [SIMD3<Float>]
        if let limit, stored.count > limit {
            let strideValue = max(stored.count / limit, 1)
            resultPoints = Array(stored.enumerated().compactMap { index, point in
                index.isMultiple(of: strideValue) ? point : nil
            }.prefix(limit))
        } else {
            resultPoints = stored
        }

        return Snapshot(
            points: resultPoints,
            averageDepth: average,
            meshAnchorCount: anchors,
            cameraTransform: transform,
            pointCount: count
        )
    }

    private func startSession() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.worldAlignment = .gravity
        configuration.planeDetection = [.horizontal]
        configuration.frameSemantics.insert(.sceneDepth)
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.smoothedSceneDepth) {
            configuration.frameSemantics.insert(.smoothedSceneDepth)
        }

        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.meshWithClassification) {
            configuration.sceneReconstruction = .meshWithClassification
            meshSupported = true
        } else if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            configuration.sceneReconstruction = .mesh
            meshSupported = true
        } else {
            meshSupported = false
        }

        lock.lock()
        resetLocked()
        running = true
        measuring = false
        lock.unlock()

        session.run(configuration, options: [.resetTracking, .removeExistingAnchors])
        publishStatus(supported: true, running: true, measuring: false, cameraDenied: false)
    }

    private func publishStatus(supported: Bool, running: Bool, measuring: Bool, cameraDenied: Bool) {
        DispatchQueue.main.async { [weak self] in
            self?.onStatusChanged?(supported, running, measuring, cameraDenied)
        }
    }

    private func resetLocked() {
        points.removeAll(keepingCapacity: true)
        writeIndex = 0
        depthSum = 0
        depthCount = 0
        meshAnchorIDs.removeAll(keepingCapacity: true)
        lastCameraTransform = matrix_identity_float4x4
        lastProcessedTimestamp = 0
    }

    func session(_ session: ARSession, didAdd anchors: [ARAnchor]) {
        updateMeshAnchors(anchors)
    }

    func session(_ session: ARSession, didUpdate anchors: [ARAnchor]) {
        updateMeshAnchors(anchors)
    }

    func session(_ session: ARSession, didRemove anchors: [ARAnchor]) {
        lock.lock()
        for anchor in anchors where anchor is ARMeshAnchor {
            meshAnchorIDs.remove(anchor.identifier)
        }
        lock.unlock()
    }

    private func updateMeshAnchors(_ anchors: [ARAnchor]) {
        lock.lock()
        for anchor in anchors where anchor is ARMeshAnchor {
            meshAnchorIDs.insert(anchor.identifier)
        }
        lock.unlock()
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        lock.lock()
        lastCameraTransform = frame.camera.transform
        let shouldMeasure = measuring
        let elapsed = frame.timestamp - lastProcessedTimestamp
        if shouldMeasure && elapsed >= frameInterval {
            lastProcessedTimestamp = frame.timestamp
        }
        lock.unlock()

        guard shouldMeasure, elapsed >= frameInterval,
              let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth else { return }

        let batch = extractPoints(depthData: depthData, frame: frame)
        guard !batch.points.isEmpty else { return }

        lock.lock()
        appendToRingBuffer(batch.points)
        depthSum += batch.depthSum
        depthCount += batch.depthCount
        let currentCount = points.count
        lock.unlock()

        DispatchQueue.main.async { [weak self] in
            self?.onPointCountChanged?(currentCount)
            self?.onFrameProcessed?()
        }
    }

    private func appendToRingBuffer(_ batch: [SIMD3<Float>]) {
        for point in batch {
            if points.count < maximumStoredPoints {
                points.append(point)
            } else {
                points[writeIndex] = point
                writeIndex += 1
                if writeIndex >= maximumStoredPoints { writeIndex = 0 }
            }
        }
    }

    private struct PointBatch {
        let points: [SIMD3<Float>]
        let depthSum: Double
        let depthCount: Int
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

        let xStart = Int(Float(width) * 0.06)
        let xEnd = Int(Float(width) * 0.94)
        let yStart = Int(Float(height) * 0.10)
        let yEnd = Int(Float(height) * 0.92)
        let sampleColumns = 39
        let sampleRows = 29
        let neighborStep = 2

        func depthAt(_ x: Int, _ y: Int) -> Float? {
            guard x >= 0, x < width, y >= 0, y < height else { return nil }
            let row = depthBase.advanced(by: y * rowBytes).assumingMemoryBound(to: Float32.self)
            let value = row[x]
            guard value.isFinite, value > 0.22, value < 4.5 else { return nil }
            return value
        }

        func worldPoint(x: Int, y: Int, depth: Float) -> SIMD3<Float> {
            let cameraX = (Float(x) - cx) * depth / fx
            let cameraY = -(Float(y) - cy) * depth / fy
            let cameraPoint = SIMD4<Float>(cameraX, cameraY, -depth, 1)
            let world4 = frame.camera.transform * cameraPoint
            return SIMD3<Float>(world4.x, world4.y, world4.z)
        }

        var result: [SIMD3<Float>] = []
        result.reserveCapacity(sampleColumns * sampleRows)
        var sum = 0.0
        var count = 0

        for row in 0..<sampleRows {
            let ry = Double(row) / Double(max(sampleRows - 1, 1))
            let y = min(height - 1 - neighborStep, max(0, Int(round(Double(yStart) + ry * Double(yEnd - yStart)))))

            for column in 0..<sampleColumns {
                let rx = Double(column) / Double(max(sampleColumns - 1, 1))
                let x = min(width - 1 - neighborStep, max(0, Int(round(Double(xStart) + rx * Double(xEnd - xStart)))))

                if let confidenceBase {
                    let confidenceRow = confidenceBase
                        .advanced(by: y * confidenceRowBytes)
                        .assumingMemoryBound(to: UInt8.self)
                    if confidenceRow[x] < 1 { continue }
                }

                guard let z = depthAt(x, y),
                      let zRight = depthAt(x + neighborStep, y),
                      let zDown = depthAt(x, y + neighborStep) else { continue }

                let discontinuityLimit = max(Float(0.055), z * 0.045)
                guard abs(zRight - z) <= discontinuityLimit,
                      abs(zDown - z) <= discontinuityLimit else { continue }

                let center = worldPoint(x: x, y: y, depth: z)
                let rightPoint = worldPoint(x: x + neighborStep, y: y, depth: zRight)
                let downPoint = worldPoint(x: x, y: y + neighborStep, depth: zDown)

                let tangentX = rightPoint - center
                let tangentY = downPoint - center
                let normal = simd_cross(tangentX, tangentY)
                let normalLength = simd_length(normal)
                guard normalLength > 0.0005 else { continue }

                let verticalAlignment = abs(normal.y / normalLength)
                guard verticalAlignment >= 0.78 else { continue }

                result.append(center)
                sum += Double(z)
                count += 1
            }
        }

        return PointBatch(points: result, depthSum: sum, depthCount: count)
    }

    var supportsMeshReconstruction: Bool {
        meshSupported
    }
}
