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

        var points: [SIMD3<Float>] = []
        var depthSum: Float = 0
        var candidateCount = 0

        let xStart = Int(Float(depthWidth) * 0.24)
        let xEnd = Int(Float(depthWidth) * 0.76)
        let yStart = Int(Float(depthHeight) * 0.30)
        let yEnd = Int(Float(depthHeight) * 0.70)
        let xStep = max(2, (xEnd - xStart) / 10)
        let yStep = max(2, (yEnd - yStart) / 8)

        for y in stride(from: yStart, through: yEnd, by: yStep) {
            for x in stride(from: xStart, through: xEnd, by: xStep) {
                candidateCount += 1

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
                points.append(SIMD3<Float>(worldPoint4.x, worldPoint4.y, worldPoint4.z))
                depthSum += z
            }
        }

        guard points.count >= 24 else { return nil }

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
        let normalMatrix = simd_float3x3(
            SIMD3<Float>(sxx, sxz, sx1),
            SIMD3<Float>(sxz, szz, sz1),
            SIMD3<Float>(sx1, sz1, n)
        )

        guard abs(simd_determinant(normalMatrix)) > 0.000001 else { return nil }
        let coefficients = simd_inverse(normalMatrix) * SIMD3<Float>(sxy, szy, sy1)
        let a = coefficients.x
        let b = coefficients.y

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
        let quality = min(1, Double(points.count) / Double(max(candidateCount, 1)))

        return ScanMetrics(
            slopePercent: Double(slopePercent),
            slopeDegrees: Double(slopeDegrees),
            distanceMeters: Double(depthSum / Float(points.count)),
            quality: quality,
            downhillAngleRadians: Double(downhillAngle),
            sampleCount: points.count,
            hasMeasurement: true
        )
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
