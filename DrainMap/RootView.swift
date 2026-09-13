import SwiftUI
import UIKit
import ARKit
import SceneKit
import CoreVideo
import simd

enum LivePreviewMode: String, CaseIterable, Identifiable {
    case slopes = "Pendenze"
    case water = "Acqua"
    case camera = "Camera"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .slopes: return "thermometer.medium"
        case .water: return "drop.fill"
        case .camera: return "camera.fill"
        }
    }
}

@MainActor
final class LiveSurfacePreviewState: ObservableObject {
    @Published var minimumMillimeters: Double = -10
    @Published var maximumMillimeters: Double = 10
    @Published var visibleCoverage: Double = 0
    @Published var surfaceReady = false

    var minimumLabel: String { String(format: "%+.0f mm", minimumMillimeters) }
    var maximumLabel: String { String(format: "%+.0f mm", maximumMillimeters) }
}

struct RootView: View {
    var body: some View {
        TabView {
            LiveDrainScanView()
                .tabItem { Label("Scansione", systemImage: "viewfinder") }

            SettingsView()
                .tabItem { Label("Manuale", systemImage: "book.closed") }

            HistoryView()
                .tabItem { Label("Libreria", systemImage: "square.stack.3d.up") }
        }
        .tint(.cyan)
    }
}

struct LiveDrainScanView: View {
    @EnvironmentObject private var store: ScanStore
    @StateObject private var scanner = LiDARScanner()
    @StateObject private var previewState = LiveSurfacePreviewState()

    @State private var analyzedMetrics: ScanMetrics?
    @State private var showAnalysis = false
    @State private var previewMode: LivePreviewMode = .slopes
    @State private var rainIntensity = 0.55

    private var pointReady: Bool {
        scanner.acquiredPointCount >= scanner.minimumRequiredPoints
    }

    private var coverageReady: Bool {
        scanner.metrics.coverage >= scanner.minimumRequiredCoverage
    }

    private var canAnalyze: Bool {
        scanner.metrics.hasMeasurement && pointReady && coverageReady
    }

    private var previewActive: Bool {
        scanner.isMeasuring
    }

    private var preservePreview: Bool {
        analyzedMetrics != nil
    }

    var body: some View {
        ZStack {
            if scanner.cameraDenied {
                cameraDeniedView
            } else if scanner.isSupported {
                ARSurfacePreviewView(
                    scanner: scanner,
                    mode: previewMode,
                    rainIntensity: rainIntensity,
                    active: previewActive,
                    preserveWhenInactive: preservePreview,
                    previewState: previewState
                )
                .ignoresSafeArea()
            } else {
                unsupportedView
            }

            LinearGradient(
                colors: [.black.opacity(0.46), .clear, .clear, .black.opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            if !scanner.cameraDenied, scanner.isSupported {
                VStack(spacing: 9) {
                    statusBar
                    Spacer(minLength: 4)
                    scanViewport
                    Spacer(minLength: 8)
                    controlPanel
                }
                .padding(.horizontal, 12)
                .padding(.top, 7)
                .padding(.bottom, 6)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { scanner.start() }
        .fullScreenCover(isPresented: $showAnalysis) {
            if let analyzedMetrics {
                DrainMapAnalysisStudio(
                    metrics: analyzedMetrics,
                    measuredAt: .now,
                    onSave: {
                        store.add(ScanRecord(metrics: analyzedMetrics))
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    },
                    onNewScan: {
                        showAnalysis = false
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            startScan()
                        }
                    }
                )
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 9) {
            Circle()
                .fill(scanner.isMeasuring ? Color.cyan : analyzedMetrics != nil ? Color.green : Color.orange)
                .frame(width: 8, height: 8)
                .shadow(color: scanner.isMeasuring ? .cyan : .clear, radius: 6)

            Text(statusText)
                .font(.caption.weight(.semibold))

            Spacer()

            if scanner.isMeasuring {
                Text("\(scanner.acquiredPointCount.formatted()) pt")
                    .font(.caption2.weight(.bold))
                    .monospacedDigit()
                    .foregroundStyle(.cyan)
            }

            Text("DRAINMAP")
                .font(.caption2.weight(.bold))
                .tracking(1.8)
                .foregroundStyle(.cyan)
        }
        .padding(.horizontal, 13)
        .frame(height: 42)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().stroke(.white.opacity(0.12)))
    }

    private var statusText: String {
        if scanner.isMeasuring {
            return previewMode == .water ? "Simulazione deflusso live" : "Mappa pendenze LiDAR live"
        }
        if analyzedMetrics != nil { return "Rilievo completato" }
        return scanner.isRunning ? "Pronto alla scansione" : "Avvio LiDAR…"
    }

    private var scanViewport: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(.white.opacity(scanner.isMeasuring ? 0.55 : 0.32), lineWidth: 1.5)

            if previewMode == .slopes && (scanner.isMeasuring || analyzedMetrics != nil) {
                altitudeLegend
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.top, 18)
                    .padding(.leading, 14)
            }

            VStack {
                HStack {
                    Spacer()
                    Text(scanner.isMeasuring ? "LIVE AR" : analyzedMetrics != nil ? "RILIEVO" : "LiDAR")
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .background(.blue.opacity(0.84), in: Capsule())
                }
                .padding(13)

                Spacer()

                if scanner.isMeasuring || analyzedMetrics != nil {
                    liveMetricCards
                        .padding(.horizontal, 10)
                        .padding(.bottom, 9)
                } else {
                    Label("Inquadra il pavimento o il terrazzo", systemImage: "scope")
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.52), in: Capsule())
                        .padding(.bottom, 10)
                }

                previewModePicker
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
            }
        }
        .frame(height: 405)
        .allowsHitTesting(true)
    }

    private var altitudeLegend: some View {
        HStack(spacing: 9) {
            LinearGradient(
                colors: [.red, .orange, .yellow, .green, .cyan, .blue],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(width: 13, height: 116)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            VStack(alignment: .leading) {
                Text(previewState.maximumLabel)
                Spacer()
                Text("0 mm")
                Spacer()
                Text(previewState.minimumLabel)
            }
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
        }
        .padding(11)
        .frame(height: 142)
        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.12)))
    }

    private var liveMetricCards: some View {
        HStack(spacing: 7) {
            previewMetric(
                "Pendenza media",
                scanner.metrics.hasMeasurement ? String(format: "%.1f %%", scanner.metrics.slopePercent) : "—"
            )
            previewMetric(
                "Punto più basso",
                scanner.metrics.hasMeasurement ? scanner.metrics.minimumHeightLabel : previewState.minimumLabel
            )
            previewMetric(
                "Punto più alto",
                scanner.metrics.hasMeasurement ? scanner.metrics.maximumHeightLabel : previewState.maximumLabel
            )
        }
    }

    private func previewMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white.opacity(0.78))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(value)
                .font(.headline.weight(.semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 9)
        .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 13).stroke(.white.opacity(0.10)))
    }

    private var previewModePicker: some View {
        HStack(spacing: 5) {
            ForEach(LivePreviewMode.allCases) { mode in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        previewMode = mode
                    }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: mode.icon)
                        Text(mode.rawValue)
                    }
                    .font(.caption2.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 37)
                    .foregroundStyle(previewMode == mode ? .black : .white)
                    .background(
                        previewMode == mode ? Color.white : Color.black.opacity(0.58),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(5)
        .background(.black.opacity(0.46), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    }

    private var controlPanel: some View {
        VStack(spacing: 10) {
            if scanner.isMeasuring {
                if previewMode == .water {
                    rainControl
                }

                progressLine(
                    title: "PUNTI LiDAR",
                    value: "\(scanner.acquiredPointCount.formatted()) / \(scanner.minimumRequiredPoints.formatted())",
                    progress: min(Double(scanner.acquiredPointCount) / Double(scanner.minimumRequiredPoints), 1),
                    ready: pointReady
                )

                progressLine(
                    title: "COPERTURA SUPERFICIE",
                    value: "\(scanner.metrics.coverageLabel) / \(Int(scanner.minimumRequiredCoverage * 100))%",
                    progress: min(scanner.metrics.coverage / scanner.minimumRequiredCoverage, 1),
                    ready: coverageReady
                )

                HStack(spacing: 10) {
                    Button(action: cancelScan) {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .frame(width: 52, height: 52)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))

                    Button(action: finishScan) {
                        Label(buttonTitle, systemImage: canAnalyze ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right")
                            .fontWeight(.semibold)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .frame(maxWidth: .infinity)
                            .frame(height: 52)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(canAnalyze ? .black : .white.opacity(0.58))
                    .background(canAnalyze ? Color.cyan : Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))
                    .disabled(!canAnalyze)
                }

                Text(scanHint)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if analyzedMetrics != nil {
                HStack(spacing: 10) {
                    Button(action: startScan) {
                        Label("Nuovo", systemImage: "arrow.counterclockwise")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                    .background(.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 15))

                    Button {
                        showAnalysis = true
                    } label: {
                        Label("Dettagli", systemImage: "chart.xyaxis.line")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .frame(height: 50)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.black)
                    .background(Color.cyan, in: RoundedRectangle(cornerRadius: 15))
                }
            } else {
                Button(action: startScan) {
                    Label("Avvia scansione LiDAR", systemImage: "viewfinder")
                        .fontWeight(.semibold)
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.black)
                .background(Color.cyan, in: RoundedRectangle(cornerRadius: 16))

                Text("Heatmap AR live · minimo 15.000 punti · copertura minima 60%")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(13)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(.white.opacity(0.12)))
    }

    private var rainControl: some View {
        VStack(spacing: 6) {
            HStack {
                Text("INTENSITÀ PIOGGIA")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(rainIntensity < 0.4 ? "Leggera" : rainIntensity < 0.75 ? "Media" : "Forte")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.cyan)
            }
            Slider(value: $rainIntensity, in: 0.2...1)
                .tint(.cyan)
        }
    }

    private var scanHint: String {
        if !pointReady {
            return "Muovi lentamente sull’intera superficie: servono almeno 15.000 punti reali prima dell’analisi."
        }
        if !coverageReady {
            return "Punti sufficienti. Continua a muovere l’iPhone finché la copertura raggiunge almeno il 60%."
        }
        return "Rilievo valido. Puoi concludere oppure continuare per aumentare la qualità."
    }

    private var buttonTitle: String {
        if !pointReady {
            return "Ancora \(max(scanner.minimumRequiredPoints - scanner.acquiredPointCount, 0).formatted()) punti"
        }
        if !coverageReady { return "Aumenta copertura" }
        return "Concludi rilievo"
    }

    private func progressLine(title: String, value: String, progress: Double, ready: Bool) -> some View {
        VStack(spacing: 5) {
            HStack {
                Text(title)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
                Spacer()
                if ready {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Text(value)
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(ready ? .green : .cyan)
            }
            ProgressView(value: progress)
                .tint(ready ? .green : .cyan)
        }
    }

    private func startScan() {
        analyzedMetrics = nil
        previewMode = .slopes
        if scanner.isRunning {
            scanner.beginMeasurement()
        } else {
            scanner.start()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                scanner.beginMeasurement()
            }
        }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    private func cancelScan() {
        analyzedMetrics = nil
        scanner.cancelMeasurement()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    private func finishScan() {
        guard canAnalyze, let result = scanner.finishMeasurement() else { return }
        analyzedMetrics = result
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private var unsupportedView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "sensor.tag.radiowaves.forward")
                    .font(.system(size: 44, weight: .thin))
                    .foregroundStyle(.cyan)
                Text("DrainMap richiede un iPhone con LiDAR")
                    .foregroundStyle(.white)
            }
        }
    }

    private var cameraDeniedView: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                Image(systemName: "camera.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.cyan)
                Text("Abilita la fotocamera per usare LiDAR e anteprima AR")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white)
                Button("Apri Impostazioni") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            }
            .padding(24)
        }
    }
}

struct ARSurfacePreviewView: UIViewRepresentable {
    @ObservedObject var scanner: LiDARScanner
    let mode: LivePreviewMode
    let rainIntensity: Double
    let active: Bool
    let preserveWhenInactive: Bool
    @ObservedObject var previewState: LiveSurfacePreviewState

    func makeUIView(context: Context) -> ARSurfacePreviewContainer {
        let view = ARSurfacePreviewContainer()
        view.sceneView.session = scanner.session
        view.configure(
            mode: mode,
            rainIntensity: rainIntensity,
            active: active,
            preserveWhenInactive: preserveWhenInactive,
            previewState: previewState
        )
        return view
    }

    func updateUIView(_ uiView: ARSurfacePreviewContainer, context: Context) {
        uiView.sceneView.session = scanner.session
        uiView.configure(
            mode: mode,
            rainIntensity: rainIntensity,
            active: active,
            preserveWhenInactive: preserveWhenInactive,
            previewState: previewState
        )
    }
}

final class ARSurfacePreviewContainer: UIView {
    let sceneView = ARSCNView(frame: .zero)

    private let surfaceNode = SCNNode()
    private let flowNode = SCNNode()
    private var displayLink: CADisplayLink?
    private var lastUpdateTimestamp: CFTimeInterval = 0
    private var lastRenderData: SurfaceRenderData?
    private var wasActive = false

    private var mode: LivePreviewMode = .slopes
    private var rainIntensity = 0.55
    private var active = false
    private var preserveWhenInactive = false
    private weak var previewState: LiveSurfacePreviewState?

    override init(frame: CGRect) {
        super.init(frame: frame)

        backgroundColor = .black
        sceneView.translatesAutoresizingMaskIntoConstraints = false
        sceneView.scene = SCNScene()
        sceneView.backgroundColor = .black
        sceneView.automaticallyUpdatesLighting = false
        sceneView.rendersCameraGrain = false
        sceneView.debugOptions = []
        addSubview(sceneView)

        NSLayoutConstraint.activate([
            sceneView.leadingAnchor.constraint(equalTo: leadingAnchor),
            sceneView.trailingAnchor.constraint(equalTo: trailingAnchor),
            sceneView.topAnchor.constraint(equalTo: topAnchor),
            sceneView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        surfaceNode.renderingOrder = 100
        flowNode.renderingOrder = 110
        sceneView.scene.rootNode.addChildNode(surfaceNode)
        sceneView.scene.rootNode.addChildNode(flowNode)

        let link = CADisplayLink(target: self, selector: #selector(displayTick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 8, maximum: 12, preferred: 10)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        displayLink?.invalidate()
    }

    func configure(
        mode: LivePreviewMode,
        rainIntensity: Double,
        active: Bool,
        preserveWhenInactive: Bool,
        previewState: LiveSurfacePreviewState
    ) {
        let modeChanged = self.mode != mode
        self.mode = mode
        self.rainIntensity = rainIntensity
        self.previewState = previewState
        self.preserveWhenInactive = preserveWhenInactive

        if active && !wasActive {
            clearPreview(resetState: true)
        }

        self.active = active
        wasActive = active

        if modeChanged, let lastRenderData {
            apply(renderData: lastRenderData)
        }

        if !active && !preserveWhenInactive {
            clearPreview(resetState: true)
        }
    }

    @objc private func displayTick(_ link: CADisplayLink) {
        guard active else { return }
        guard link.timestamp - lastUpdateTimestamp >= 0.095 else { return }
        lastUpdateTimestamp = link.timestamp

        guard mode != .camera,
              let frame = sceneView.session.currentFrame,
              let depthData = frame.smoothedSceneDepth ?? frame.sceneDepth,
              let renderData = buildRenderData(depthData: depthData, frame: frame) else {
            if mode == .camera {
                surfaceNode.geometry = nil
                flowNode.geometry = nil
            }
            return
        }

        lastRenderData = renderData
        apply(renderData: renderData)
    }

    private func clearPreview(resetState: Bool) {
        surfaceNode.geometry = nil
        flowNode.geometry = nil
        flowNode.removeAllActions()
        lastRenderData = nil

        if resetState {
            previewState?.minimumMillimeters = -10
            previewState?.maximumMillimeters = 10
            previewState?.visibleCoverage = 0
            previewState?.surfaceReady = false
        }
    }

    private func apply(renderData: SurfaceRenderData) {
        guard mode != .camera else {
            surfaceNode.geometry = nil
            flowNode.geometry = nil
            return
        }

        surfaceNode.geometry = makeSurfaceGeometry(renderData)

        if mode == .water {
            flowNode.geometry = makeFlowGeometry(renderData.flowSegments)
            if flowNode.action(forKey: "waterPulse") == nil {
                let pulse = SCNAction.sequence([
                    .fadeOpacity(to: 0.48, duration: 0.45),
                    .fadeOpacity(to: 1.0, duration: 0.45)
                ])
                flowNode.runAction(.repeatForever(pulse), forKey: "waterPulse")
            }
        } else {
            flowNode.geometry = nil
            flowNode.removeAllActions()
            flowNode.opacity = 1
        }

        previewState?.minimumMillimeters = renderData.minimumMillimeters
        previewState?.maximumMillimeters = renderData.maximumMillimeters
        previewState?.visibleCoverage = renderData.coverage
        previewState?.surfaceReady = true
    }

    private func makeSurfaceGeometry(_ renderData: SurfaceRenderData) -> SCNGeometry {
        let vertices = renderData.vertices.map { SCNVector3($0.x, $0.y, $0.z) }
        let vertexSource = SCNGeometrySource(vertices: vertices)

        let colors: [SIMD4<Float>] = renderData.normalizedHeights.map { normalized in
            switch mode {
            case .slopes:
                return heatColor(normalized)
            case .water:
                let low = 1 - normalized
                let alpha = Float(0.16 + low * 0.34 + rainIntensity * 0.17)
                return SIMD4<Float>(0.02, 0.43, 1.0, min(alpha, 0.68))
            case .camera:
                return SIMD4<Float>(0, 0, 0, 0)
            }
        }

        let colorData = colors.withUnsafeBytes { Data($0) }
        let colorSource = SCNGeometrySource(
            data: colorData,
            semantic: .color,
            vectorCount: colors.count,
            usesFloatComponents: true,
            componentsPerVector: 4,
            bytesPerComponent: MemoryLayout<Float>.size,
            dataOffset: 0,
            dataStride: MemoryLayout<SIMD4<Float>>.stride
        )

        let indexData = renderData.triangleIndices.withUnsafeBytes { Data($0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: renderData.triangleIndices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white
        material.isDoubleSided = true
        material.blendMode = .alpha
        material.transparencyMode = .dualLayer
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        geometry.materials = [material]
        return geometry
    }

    private func makeFlowGeometry(_ segments: [(SIMD3<Float>, SIMD3<Float>)]) -> SCNGeometry? {
        guard !segments.isEmpty else { return nil }

        var vertices: [SCNVector3] = []
        var indices: [UInt32] = []
        vertices.reserveCapacity(segments.count * 2)
        indices.reserveCapacity(segments.count * 2)

        for segment in segments {
            let startIndex = UInt32(vertices.count)
            vertices.append(SCNVector3(segment.0.x, segment.0.y + 0.008, segment.0.z))
            vertices.append(SCNVector3(segment.1.x, segment.1.y + 0.008, segment.1.z))
            indices.append(startIndex)
            indices.append(startIndex + 1)
        }

        let source = SCNGeometrySource(vertices: vertices)
        let indexData = indices.withUnsafeBytes { Data($0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .line,
            primitiveCount: indices.count / 2,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geometry = SCNGeometry(sources: [source], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white.withAlphaComponent(0.94)
        material.emission.contents = UIColor.white.withAlphaComponent(0.70)
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        geometry.materials = [material]
        return geometry
    }

    private func heatColor(_ value: Float) -> SIMD4<Float> {
        let t = min(max(value, 0), 1)
        let color = UIColor(
            hue: CGFloat(0.66 * (1 - t)),
            saturation: 0.96,
            brightness: 1.0,
            alpha: 0.56
        )
        var r: CGFloat = 0
        var g: CGFloat = 0
        var b: CGFloat = 0
        var a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return SIMD4<Float>(Float(r), Float(g), Float(b), Float(a))
    }

    private func buildRenderData(depthData: ARDepthData, frame: ARFrame) -> SurfaceRenderData? {
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

        let resolution = frame.camera.imageResolution
        let sx = Float(depthWidth) / Float(resolution.width)
        let sy = Float(depthHeight) / Float(resolution.height)
        let intrinsics = frame.camera.intrinsics
        let fx = intrinsics.columns.0.x * sx
        let fy = intrinsics.columns.1.y * sy
        let cx = intrinsics.columns.2.x * sx
        let cy = intrinsics.columns.2.y * sy

        let columns = 39
        let rows = 29
        let count = columns * rows
        let xStart = Int(Float(depthWidth) * 0.08)
        let xEnd = Int(Float(depthWidth) * 0.92)
        let yStart = Int(Float(depthHeight) * 0.12)
        let yEnd = Int(Float(depthHeight) * 0.90)

        var vertices = Array(repeating: SIMD3<Float>(repeating: 0), count: count)
        var depths = Array(repeating: Float.nan, count: count)
        var heights = Array<Double?>(repeating: nil, count: count)
        var rawHeights: [Double] = []
        rawHeights.reserveCapacity(count)

        for row in 0..<rows {
            let rowRatio = Double(row) / Double(max(rows - 1, 1))
            let y = min(depthHeight - 1, max(0, Int(round(Double(yStart) + rowRatio * Double(yEnd - yStart)))))

            for column in 0..<columns {
                let columnRatio = Double(column) / Double(max(columns - 1, 1))
                let x = min(depthWidth - 1, max(0, Int(round(Double(xStart) + columnRatio * Double(xEnd - xStart)))))

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
                guard z.isFinite, z > 0.25, z < 5.0 else { continue }

                let cameraX = (Float(x) - cx) * z / fx
                let cameraY = -(Float(y) - cy) * z / fy
                let cameraPoint = SIMD4<Float>(cameraX, cameraY, -z, 1)
                let world4 = frame.camera.transform * cameraPoint
                let world = SIMD3<Float>(world4.x, world4.y, world4.z)
                let index = row * columns + column

                vertices[index] = world
                depths[index] = z
                heights[index] = Double(world.y)
                rawHeights.append(Double(world.y))
            }
        }

        guard rawHeights.count >= 80 else { return nil }

        let binSize = 0.04
        var histogram: [Int: Int] = [:]
        for height in rawHeights {
            let key = Int(floor(height / binSize))
            histogram[key, default: 0] += 1
        }
        guard let dominantBin = histogram.max(by: { $0.value < $1.value })?.key else { return nil }
        let dominantCenter = (Double(dominantBin) + 0.5) * binSize

        var candidateMask = Array(repeating: false, count: count)
        for index in 0..<count {
            if let height = heights[index], abs(height - dominantCenter) <= 0.18 {
                candidateMask[index] = true
            }
        }

        let component = largestGridComponent(mask: candidateMask, columns: columns, rows: rows)
        guard component.count >= 45 else { return nil }

        var validMask = Array(repeating: false, count: count)
        for index in component { validMask[index] = true }

        let validHeights = component.compactMap { heights[$0] }
        guard validHeights.count >= 45 else { return nil }

        let medianHeight = quantile(validHeights, 0.50)
        let lowHeight = quantile(validHeights, 0.03)
        let highHeight = quantile(validHeights, 0.97)
        let rawHalfRange = max(abs(highHeight - medianHeight), abs(medianHeight - lowHeight))
        let displayHalfRange = min(max(rawHalfRange, 0.010), 0.080)

        var normalizedHeights = Array(repeating: Float(0.5), count: count)
        for index in component {
            guard let height = heights[index] else { continue }
            let normalized = 0.5 + (height - medianHeight) / (displayHalfRange * 2)
            normalizedHeights[index] = Float(min(max(normalized, 0), 1))
        }

        var triangleIndices: [UInt32] = []
        triangleIndices.reserveCapacity((columns - 1) * (rows - 1) * 6)

        for row in 0..<(rows - 1) {
            for column in 0..<(columns - 1) {
                let i00 = row * columns + column
                let i10 = row * columns + column + 1
                let i01 = (row + 1) * columns + column
                let i11 = (row + 1) * columns + column + 1

                guard validMask[i00], validMask[i10], validMask[i01], validMask[i11] else { continue }
                guard surfaceQuadIsContinuous(
                    [i00, i10, i01, i11],
                    vertices: vertices,
                    depths: depths
                ) else { continue }

                triangleIndices.append(contentsOf: [
                    UInt32(i00), UInt32(i01), UInt32(i10),
                    UInt32(i10), UInt32(i01), UInt32(i11)
                ])
            }
        }

        guard triangleIndices.count >= 90 else { return nil }

        var flowSegments: [(SIMD3<Float>, SIMD3<Float>)] = []
        flowSegments.reserveCapacity(140)

        for row in stride(from: 1, to: rows - 1, by: 2) {
            for column in stride(from: 1, to: columns - 1, by: 2) {
                let index = row * columns + column
                guard validMask[index], let currentHeight = heights[index] else { continue }

                var bestIndex = index
                var bestHeight = currentHeight

                for dr in -1...1 {
                    for dc in -1...1 where !(dc == 0 && dr == 0) {
                        let nr = row + dr
                        let nc = column + dc
                        guard nr >= 0, nr < rows, nc >= 0, nc < columns else { continue }
                        let candidate = nr * columns + nc
                        guard validMask[candidate], let candidateHeight = heights[candidate] else { continue }
                        if candidateHeight < bestHeight - 0.0012 {
                            bestHeight = candidateHeight
                            bestIndex = candidate
                        }
                    }
                }

                if bestIndex != index {
                    flowSegments.append((vertices[index], vertices[bestIndex]))
                }
            }
        }

        let coverage = Double(component.count) / Double(count)
        return SurfaceRenderData(
            vertices: vertices,
            normalizedHeights: normalizedHeights,
            triangleIndices: triangleIndices,
            flowSegments: flowSegments,
            minimumMillimeters: -displayHalfRange * 1000,
            maximumMillimeters: displayHalfRange * 1000,
            coverage: coverage
        )
    }

    private func surfaceQuadIsContinuous(
        _ indices: [Int],
        vertices: [SIMD3<Float>],
        depths: [Float]
    ) -> Bool {
        guard indices.count == 4 else { return false }
        let firstDepth = depths[indices[0]]
        guard firstDepth.isFinite else { return false }

        for index in indices.dropFirst() {
            guard depths[index].isFinite,
                  abs(depths[index] - firstDepth) < 0.38,
                  abs(vertices[index].y - vertices[indices[0]].y) < 0.16 else { return false }
        }
        return true
    }

    private func largestGridComponent(mask: [Bool], columns: Int, rows: Int) -> Set<Int> {
        guard mask.count == columns * rows else { return [] }
        var visited = Set<Int>()
        var best = Set<Int>()

        for start in mask.indices where mask[start] && !visited.contains(start) {
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

                for (nc, nr) in [
                    (column - 1, row),
                    (column + 1, row),
                    (column, row - 1),
                    (column, row + 1)
                ] {
                    guard nc >= 0, nc < columns, nr >= 0, nr < rows else { continue }
                    let next = nr * columns + nc
                    guard mask[next], !visited.contains(next) else { continue }
                    visited.insert(next)
                    queue.append(next)
                }
            }

            if component.count > best.count { best = component }
        }
        return best
    }

    private func quantile(_ values: [Double], _ q: Double) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let position = min(max(q, 0), 1) * Double(sorted.count - 1)
        let lower = Int(floor(position))
        let upper = Int(ceil(position))
        if lower == upper { return sorted[lower] }
        let fraction = position - Double(lower)
        return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
    }
}

private struct SurfaceRenderData {
    let vertices: [SIMD3<Float>]
    let normalizedHeights: [Float]
    let triangleIndices: [UInt32]
    let flowSegments: [(SIMD3<Float>, SIMD3<Float>)]
    let minimumMillimeters: Double
    let maximumMillimeters: Double
    let coverage: Double
}
