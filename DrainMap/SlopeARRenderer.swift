import ARKit
import SceneKit
import SwiftUI
import UIKit

final class SlopeARRenderer {
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

        var textureCoordinates: [CGPoint] = []
        textureCoordinates.reserveCapacity(surface.vertices.count)
        for row in 0..<surface.rows {
            let v = 1 - CGFloat(row) / CGFloat(max(surface.rows - 1, 1))
            for column in 0..<surface.columns {
                let u = CGFloat(column) / CGFloat(max(surface.columns - 1, 1))
                textureCoordinates.append(CGPoint(x: u, y: v))
            }
        }
        let textureSource = SCNGeometrySource(textureCoordinates: textureCoordinates)

        let indexData = surface.triangleIndices.withUnsafeBytes { Data($0) }
        let element = SCNGeometryElement(
            data: indexData,
            primitiveType: .triangles,
            primitiveCount: surface.triangleIndices.count / 3,
            bytesPerIndex: MemoryLayout<UInt32>.size
        )

        let geometry = SCNGeometry(sources: [vertexSource, textureSource], elements: [element])
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = makeTexture(surface: surface, mode: mode, opacity: opacity)
        material.diffuse.magnificationFilter = .linear
        material.diffuse.minificationFilter = .linear
        material.diffuse.mipFilter = .linear
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        material.isDoubleSided = true
        material.blendMode = .alpha
        material.transparencyMode = .aOne
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        geometry.materials = [material]
        return geometry
    }

    private func makeTexture(surface: SurfaceGeometrySnapshot, mode: SurfaceRenderMode, opacity: Float) -> UIImage {
        let width = max(surface.columns, 2)
        let height = max(surface.rows, 2)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        format.opaque = false

        return UIGraphicsImageRenderer(
            size: CGSize(width: CGFloat(width), height: CGFloat(height)),
            format: format
        ).image { context in
            context.cgContext.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.cgContext.interpolationQuality = .high

            for row in 0..<surface.rows {
                for column in 0..<surface.columns {
                    let index = row * surface.columns + column
                    guard surface.validMask.indices.contains(index), surface.validMask[index] else { continue }

                    let normalized = surface.normalizedHeights.indices.contains(index)
                        ? surface.normalizedHeights[index]
                        : 0.5

                    let color: SIMD4<Float>
                    switch mode {
                    case .altimetry:
                        var heat = heatColor(normalized)
                        heat.w = opacity
                        color = heat
                    case .water:
                        let depression = surface.depressionGrid.indices.contains(index)
                            ? max(surface.depressionGrid[index], 0)
                            : 0
                        let low = 1 - normalized
                        let accumulation = min(Float(depression / 18.0), 1)
                        let alpha = min(0.26 + low * 0.24 + accumulation * 0.28, 0.78)
                        color = SIMD4<Float>(0.01, 0.42 + low * 0.16, 1.0, alpha)
                    case .camera:
                        color = SIMD4<Float>(0, 0, 0, 0)
                    }

                    let uiColor = UIColor(
                        red: CGFloat(color.x),
                        green: CGFloat(color.y),
                        blue: CGFloat(color.z),
                        alpha: CGFloat(color.w)
                    )
                    uiColor.setFill()
                    context.cgContext.fill(
                        CGRect(
                            x: CGFloat(column) - 0.04,
                            y: CGFloat(row) - 0.04,
                            width: 1.08,
                            height: 1.08
                        )
                    )
                }
            }
        }
    }

    private func heatColor(_ value: Float) -> SIMD4<Float> {
        let t = min(max(value, 0), 1)
        if t < 0.18 {
            let u = t / 0.18
            return mix(SIMD4<Float>(0.00, 0.16, 1.00, 1), SIMD4<Float>(0.00, 0.82, 1.00, 1), u)
        } else if t < 0.40 {
            let u = (t - 0.18) / 0.22
            return mix(SIMD4<Float>(0.00, 0.82, 1.00, 1), SIMD4<Float>(0.00, 0.90, 0.30, 1), u)
        } else if t < 0.62 {
            let u = (t - 0.40) / 0.22
            return mix(SIMD4<Float>(0.00, 0.90, 0.30, 1), SIMD4<Float>(1.00, 0.94, 0.00, 1), u)
        } else if t < 0.82 {
            let u = (t - 0.62) / 0.20
            return mix(SIMD4<Float>(1.00, 0.94, 0.00, 1), SIMD4<Float>(1.00, 0.42, 0.00, 1), u)
        } else {
            let u = (t - 0.82) / 0.18
            return mix(SIMD4<Float>(1.00, 0.42, 0.00, 1), SIMD4<Float>(1.00, 0.02, 0.02, 1), u)
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
            signature = "\(surface.metrics.sampleCount)-\(surface.metrics.coverage)-\(surface.metrics.reliefMillimeters)-\(mode)-\(rainIntensity)-\(animateWater)"
        } else {
            signature = "empty-\(mode)"
        }
        guard signature != renderedSignature else { return }
        renderedSignature = signature

        surfaceNode?.removeFromParentNode()
        flowRoot?.removeFromParentNode()
        surfaceNode = nil
        flowRoot = nil

        guard let surface, surface.isValid, mode != .camera else { return }

        let node = slopeRenderer.makeSurfaceNode(
            surface: surface,
            opacity: mode == .water ? 0.50 : 0.60
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
