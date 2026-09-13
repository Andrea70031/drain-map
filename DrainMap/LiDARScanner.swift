import ARKit
import Combine
import Foundation

final class LiDARScanner: ObservableObject {
    let minimumRequiredPoints = 15_000
    let minimumRequiredCoverage = 0.60

    @Published private(set) var metrics = ScanMetrics()
    @Published private(set) var latestSurface: SurfaceGeometrySnapshot?
    @Published private(set) var waterFlow: WaterFlowField = .empty
    @Published private(set) var qualityAssessment = ScanQualityAssessment(score: 0, isSufficient: false, warning: "Avvia una scansione.")
    @Published private(set) var acquiredPointCount = 0
    @Published private(set) var isSupported = true
    @Published private(set) var isRunning = false
    @Published private(set) var isMeasuring = false
    @Published private(set) var cameraDenied = false

    private let acquisition = LiDARAcquisitionEngine(maximumStoredPoints: 50_000)
    private let reconstruction = SurfaceReconstructionEngine(columns: 37, rows: 29)
    private let waterEngine = WaterFlowEngine()
    private let qualityEngine = ScanQualityEngine(minimumPoints: 15_000, minimumCoverage: 0.60)
    private let analysisQueue = DispatchQueue(label: "DrainMap.surface.analysis", qos: .userInitiated)

    private var isAnalysisRunning = false
    private var lastLiveAnalysisDate = Date.distantPast

    var session: ARSession { acquisition.session }
    var supportsMeshReconstruction: Bool { acquisition.supportsMeshReconstruction }

    var canFinalize: Bool {
        acquiredPointCount >= minimumRequiredPoints &&
        metrics.coverage >= minimumRequiredCoverage &&
        qualityAssessment.isSufficient
    }

    init() {
        acquisition.onStatusChanged = { [weak self] supported, running, measuring, denied in
            guard let self else { return }
            self.isSupported = supported
            self.isRunning = running
            self.isMeasuring = measuring
            self.cameraDenied = denied
        }

        acquisition.onPointCountChanged = { [weak self] count in
            self?.acquiredPointCount = count
        }

        acquisition.onFrameProcessed = { [weak self] in
            self?.scheduleLiveReconstructionIfNeeded()
        }
    }

    func start() {
        acquisition.start()
    }

    func beginMeasurement() {
        latestSurface = nil
        waterFlow = .empty
        metrics = ScanMetrics()
        acquiredPointCount = 0
        qualityAssessment = ScanQualityAssessment(score: 0, isSufficient: false, warning: "Acquisizione in corso…")
        lastLiveAnalysisDate = .distantPast
        acquisition.beginMeasurement()
    }

    @discardableResult
    func finishMeasurement() -> ScanMetrics? {
        let snapshot = acquisition.snapshot(limit: 32_000)
        guard snapshot.pointCount >= minimumRequiredPoints,
              let rawSurface = reconstruction.reconstruct(
                points: snapshot.points,
                cameraTransform: snapshot.cameraTransform,
                averageDepth: snapshot.averageDepth,
                meshAnchorCount: snapshot.meshAnchorCount,
                pointLimit: 28_000
              ) else {
            return nil
        }

        let assessment = qualityEngine.evaluate(
            pointCount: snapshot.pointCount,
            coverage: rawSurface.metrics.coverage,
            residualMADMillimeters: rawSurface.residualMADMillimeters,
            connectedCoverage: rawSurface.connectedCoverage
        )
        guard assessment.isSufficient else {
            qualityAssessment = assessment
            return nil
        }

        var finalMetrics = rawSurface.metrics
        finalMetrics.sampleCount = snapshot.pointCount
        finalMetrics.quality = assessment.score
        let finalSurface = replacingMetrics(in: rawSurface, with: finalMetrics)

        latestSurface = finalSurface
        waterFlow = waterEngine.makeField(surface: finalSurface)
        metrics = finalMetrics
        qualityAssessment = assessment
        acquisition.stopMeasuringPreservingData()
        return finalMetrics
    }

    func cancelMeasurement() {
        acquisition.cancelMeasurement()
        latestSurface = nil
        waterFlow = .empty
        metrics = ScanMetrics()
        acquiredPointCount = 0
        qualityAssessment = ScanQualityAssessment(score: 0, isSufficient: false, warning: "Scansione annullata.")
    }

    func pause() {
        acquisition.pause()
    }

    private func scheduleLiveReconstructionIfNeeded() {
        guard isMeasuring else { return }
        guard acquiredPointCount >= 700 else { return }
        guard !isAnalysisRunning else { return }
        guard Date().timeIntervalSince(lastLiveAnalysisDate) >= 0.45 else { return }

        isAnalysisRunning = true
        lastLiveAnalysisDate = Date()
        let snapshot = acquisition.snapshot(limit: 14_000)

        analysisQueue.async { [weak self] in
            guard let self else { return }
            let surface = self.reconstruction.reconstruct(
                points: snapshot.points,
                cameraTransform: snapshot.cameraTransform,
                averageDepth: snapshot.averageDepth,
                meshAnchorCount: snapshot.meshAnchorCount,
                pointLimit: 12_000
            )

            DispatchQueue.main.async {
                defer { self.isAnalysisRunning = false }
                guard self.isMeasuring, let surface else { return }

                let assessment = self.qualityEngine.evaluate(
                    pointCount: snapshot.pointCount,
                    coverage: surface.metrics.coverage,
                    residualMADMillimeters: surface.residualMADMillimeters,
                    connectedCoverage: surface.connectedCoverage
                )

                var liveMetrics = surface.metrics
                liveMetrics.sampleCount = snapshot.pointCount
                liveMetrics.quality = assessment.score
                let updatedSurface = self.replacingMetrics(in: surface, with: liveMetrics)

                self.latestSurface = updatedSurface
                self.waterFlow = self.waterEngine.makeField(surface: updatedSurface)
                self.metrics = liveMetrics
                self.qualityAssessment = assessment
            }
        }
    }

    private func replacingMetrics(in surface: SurfaceGeometrySnapshot, with metrics: ScanMetrics) -> SurfaceGeometrySnapshot {
        SurfaceGeometrySnapshot(
            columns: surface.columns,
            rows: surface.rows,
            vertices: surface.vertices,
            validMask: surface.validMask,
            normalizedHeights: surface.normalizedHeights,
            absoluteHeights: surface.absoluteHeights,
            localSlopeGrid: surface.localSlopeGrid,
            depressionGrid: surface.depressionGrid,
            triangleIndices: surface.triangleIndices,
            origin: surface.origin,
            right: surface.right,
            forward: surface.forward,
            uMin: surface.uMin,
            uMax: surface.uMax,
            vMin: surface.vMin,
            vMax: surface.vMax,
            residualMADMillimeters: surface.residualMADMillimeters,
            connectedCoverage: surface.connectedCoverage,
            metrics: metrics
        )
    }
}
