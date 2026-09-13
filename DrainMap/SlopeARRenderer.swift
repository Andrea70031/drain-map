import ARKit
import SceneKit
import SwiftUI
import UIKit

class SlopeARRenderer {
    func makeSurfaceNode(surface: SurfaceGeometrySnapshot, opacity: Float = 0.60) -> SCNNode {
        let geometry = makeGeometry(surface: surface, mode: .altimetry, opacity: opacity)
        let node = SCNNode(geometry: geometry)
        node.name = "drainmap.slope.surface"
        node.renderingOrder = 120
        return node
    }

    func makeGeometry(surface: SurfaceGeometrySnapshot, mode: SurfaceRenderMode, opacity: Float) -> SCNGeometry {
        let vertices = surface.vertices.map { SCNVector3($0.x, $0.y, $0.z) }
        let vertexSource = SCNGeometrySource(vertices: vertices)

        var colors: [SIMD4<Float>] = []
        colors.reserveCapacity(surface.vertices.count)

        for index in surface.vertices.indices {
            guard surface.validMask.indices.contains(index), surface.validMask[index] else {
                colors.append(SIMD4<Float>(0, 0, 0, 0))
                continue
            }
            let normalized = surface.normalizedHeights.indices.contains(index) ? surface.normalizedHeights[index] : 0.5
            switch mode {
            case .altimetry:
                var c = heatColor(normalized)
                c.w = opacity
                colors.append(c)
            case .water:
                let depression = surface.depressionGrid.indices.contains(index) ? max(surface.depressionGrid[index], 0) : 0
                let low = 1 - normalized
                let intensity = min(Float(depression / 18.0), 1)
                let alpha = min(0.30 + low * 0.26 + intensity * 0.20, 0.76)
                colors.append(SIMD4<Float>(0.01, 0.40 + low * 0.18, 1.0, alpha))
            case .camera:
                colors.append(SIMD4<Float>(0, 0, 0, 0))
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

        let indexData = surface.triangleIndices.withUnsafeBytes { Data($0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: surface.triangleIndices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geometry = SCNGeometry(sources: [vertexSource, colorSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white
        material.emission.contents = UIColor.white.withAlphaComponent(0.08)
        material.isDoubleSided = true
        material.blendMode = .alpha
        material.transparencyMode = .dualLayer
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        geometry.materials = [material]
        return geometry
    }

    private func heatColor(_ value: Float) -> SIMD4<Float> {
        let t = min(max(value, 0), 1)
        if t < 0.20 {
            let u = t / 0.20
            return mix(SIMD4<Float>(0.02, 0.20, 1.0, 1), SIMD4<Float>(0.0, 0.90, 1.0, 1), u)
        } else if t < 0.42 {
            let u = (t - 0.20) / 0.22
            return mix(SIMD4<Float>(0.0, 0.90, 1.0, 1), SIMD4<Float>(0.0, 0.92, 0.28, 1), u)
        } else if t < 0.64 {
            let u = (t - 0.42) / 0.22
            return mix(SIMD4<Float>(0.0, 0.92, 0.28, 1), SIMD4<Float>(1.0, 0.94, 0.0, 1), u)
        } else if t < 0.82 {
            let u = (t - 0.64) / 0.18
            return mix(SIMD4<Float>(1.0, 0.94, 0.0, 1), SIMD4<Float>(1.0, 0.46, 0.0, 1), u)
        } else {
            let u = (t - 0.82) / 0.18
            return mix(SIMD4<Float>(1.0, 0.46, 0.0, 1), SIMD4<Float>(1.0, 0.03, 0.02, 1), u)
        }
    }

    private func mix(_ a: SIMD4<Float>, _ b: SIMD4<Float>, _ t: Float) -> SIMD4<Float> {
        a + (b - a) * min(max(t, 0), 1)
    }
}

enum SurfaceRenderMode: Equatable {
    case altimetry
    case water
    case camera
}

enum SurfaceModelCameraMode: String, CaseIterable, Identifiable {
    case top = "Vista cima"
    case threeD = "Vista 3D"

    var id: String { rawValue }
}

struct ScannerCameraView: UIViewRepresentable {
    @ObservedObject var scanner: LiDARScanner
    var mode: SurfaceRenderMode = .altimetry
    var rainIntensity: Double = 0.55
    var animateWater = true

    func makeUIView(context: Context) -> ARSurfaceSceneView {
        let view = ARSurfaceSceneView(frame: .zero)
        view.session = scanner.session
        return view
    }

    func updateUIView(_ uiView: ARSurfaceSceneView, context: Context) {
        uiView.session = scanner.session
        uiView.update(
            surface: scanner.latestSurface,
            water: scanner.waterFlow,
            mode: mode,
            rainIntensity: rainIntensity,
            animateWater: animateWater
        )
    }
}

final class ARSurfaceSceneView: ARSCNView {
    private let slopeRenderer = SlopeARRenderer()
    private let waterRenderer = WaterARRenderer()
    private var surfaceNode: SCNNode?
    private var flowRoot: SCNNode?
    private var renderedSignature = ""

    override init(frame: CGRect, options: [String : Any]? = nil) {
        super.init(frame: frame, options: options)
        scene = SCNScene()
        backgroundColor = .black
        automaticallyUpdatesLighting = false
        debugOptions = []
        rendersCameraGrain = false
        preferredFramesPerSecond = 60
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        surface: SurfaceGeometrySnapshot?,
        water: WaterFlowField,
        mode: SurfaceRenderMode,
        rainIntensity: Double,
        animateWater: Bool
    ) {
        let signature: String
        if let surface {
            signature = "\(surface.metrics.sampleCount)-\(surface.metrics.coverage)-\(mode)-\(rainIntensity)-\(animateWater)"
        } else {
            signature = "empty-\(mode)"
        }
        guard signature != renderedSignature else { return }
        renderedSignature = signature

        surfaceNode?.removeFromParentNode()
        flowRoot?.removeFromParentNode()
        surfaceNode = nil
        flowRoot = nil

        guard let surface, mode != .camera else { return }

        let node = slopeRenderer.makeSurfaceNode(
            surface: surface,
            opacity: mode == .water ? 0.50 : 0.62
        )
        if mode == .water {
            node.geometry = slopeRenderer.makeGeometry(surface: surface, mode: .water, opacity: 0.56)
        }
        scene.rootNode.addChildNode(node)
        surfaceNode = node

        if mode == .water {
            let flow = waterRenderer.makeFlowNode(
                field: water,
                rainIntensity: rainIntensity,
                animate: animateWater
            )
            scene.rootNode.addChildNode(flow)
            flowRoot = flow
        }
    }
}

struct SurfaceModelView: UIViewRepresentable {
    let surface: SurfaceGeometrySnapshot
    var cameraMode: SurfaceModelCameraMode

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView(frame: .zero)
        view.scene = SCNScene()
        view.backgroundColor = .black
        view.allowsCameraControl = cameraMode == .threeD
        view.autoenablesDefaultLighting = false
        view.antialiasingMode = .multisampling4X
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        let scene = SCNScene()
        let renderer = SlopeARRenderer()
        let surfaceNode = renderer.makeSurfaceNode(surface: surface, opacity: 0.92)
        scene.rootNode.addChildNode(surfaceNode)

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.camera?.zNear = 0.01
        cameraNode.camera?.zFar = 20
        cameraNode.camera?.usesOrthographicProjection = cameraMode == .top

        let center = surface.origin
        let uSpan = max(surface.uMax - surface.uMin, 0.4)
        let vSpan = max(surface.vMax - surface.vMin, 0.4)
        let size = max(uSpan, vSpan)

        if cameraMode == .top {
            cameraNode.position = SCNVector3(center.x, center.y + size * 1.8 + 0.8, center.z)
            cameraNode.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0)
            cameraNode.camera?.orthographicScale = Double(size * 1.15)
        } else {
            let offset = surface.forward * (-size * 1.15) + surface.right * (size * 0.65)
            cameraNode.position = SCNVector3(center.x + offset.x, center.y + size * 0.95 + 0.45, center.z + offset.z)
            cameraNode.look(at: SCNVector3(center.x, center.y, center.z))
        }

        scene.rootNode.addChildNode(cameraNode)
        view.scene = scene
        view.pointOfView = cameraNode
        view.allowsCameraControl = cameraMode == .threeD
    }
}
