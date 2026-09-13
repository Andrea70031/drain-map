import SceneKit
import UIKit

final class WaterARRenderer {
    func makeFlowNode(field: WaterFlowField, rainIntensity: Double, animate: Bool) -> SCNNode {
        let root = SCNNode()
        root.name = "drainmap.water.flow"
        root.renderingOrder = 130

        let lineNode = makeLineNode(field: field, rainIntensity: rainIntensity)
        root.addChildNode(lineNode)

        for pool in field.pools.prefix(12) {
            let node = makePoolNode(pool: pool, rainIntensity: rainIntensity)
            root.addChildNode(node)
        }

        if animate {
            let density = max(12, min(Int(18 + rainIntensity * 44), 70))
            let segments = field.segments.filter { $0.intensity > 0.16 }
            guard !segments.isEmpty else { return root }

            for index in 0..<density {
                let segment = segments[index % segments.count]
                let particle = makeParticleNode(intensity: segment.intensity)
                particle.position = SCNVector3(segment.start.x, segment.start.y + 0.011, segment.start.z)
                let duration = max(0.28, 1.05 - Double(segment.intensity) * 0.55 - rainIntensity * 0.20)
                let move = SCNAction.move(
                    to: SCNVector3(segment.end.x, segment.end.y + 0.011, segment.end.z),
                    duration: duration
                )
                move.timingMode = .easeInEaseOut
                let reset = SCNAction.run { node in
                    node.position = SCNVector3(segment.start.x, segment.start.y + 0.011, segment.start.z)
                }
                let wait = SCNAction.wait(duration: Double(index % 7) * 0.035)
                particle.runAction(.repeatForever(.sequence([wait, move, reset])))
                root.addChildNode(particle)
            }
        }

        return root
    }

    private func makeLineNode(field: WaterFlowField, rainIntensity: Double) -> SCNNode {
        var vertices: [SCNVector3] = []
        var indices: [UInt32] = []
        vertices.reserveCapacity(field.segments.count * 2)
        indices.reserveCapacity(field.segments.count * 2)

        for segment in field.segments {
            let startIndex = UInt32(vertices.count)
            vertices.append(SCNVector3(segment.start.x, segment.start.y + 0.008, segment.start.z))
            vertices.append(SCNVector3(segment.end.x, segment.end.y + 0.008, segment.end.z))
            indices.append(startIndex)
            indices.append(startIndex + 1)
        }

        guard !vertices.isEmpty else { return SCNNode() }
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
        material.diffuse.contents = UIColor.white.withAlphaComponent(0.72 + min(rainIntensity, 1) * 0.18)
        material.emission.contents = UIColor.cyan.withAlphaComponent(0.54)
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        geometry.materials = [material]

        let node = SCNNode(geometry: geometry)
        node.renderingOrder = 132
        return node
    }

    private func makePoolNode(pool: WaterPool3D, rainIntensity: Double) -> SCNNode {
        let radius = CGFloat(pool.radius * Float(0.8 + rainIntensity * 0.45))
        let disc = SCNCylinder(radius: radius, height: 0.003)
        disc.radialSegmentCount = 48
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.systemBlue.withAlphaComponent(CGFloat(0.22 + Double(pool.strength) * 0.26))
        material.emission.contents = UIColor.cyan.withAlphaComponent(0.12)
        material.isDoubleSided = true
        material.blendMode = .alpha
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        disc.materials = [material]

        let node = SCNNode(geometry: disc)
        node.position = SCNVector3(pool.center.x, pool.center.y + 0.010, pool.center.z)
        node.renderingOrder = 131
        let pulse = SCNAction.sequence([
            .scale(to: 1.08, duration: 0.70),
            .scale(to: 0.96, duration: 0.70)
        ])
        node.runAction(.repeatForever(pulse))
        return node
    }

    private func makeParticleNode(intensity: Float) -> SCNNode {
        let sphere = SCNSphere(radius: CGFloat(0.0045 + intensity * 0.0025))
        sphere.segmentCount = 10
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = UIColor.white.withAlphaComponent(0.90)
        material.emission.contents = UIColor.cyan.withAlphaComponent(0.75)
        material.readsFromDepthBuffer = true
        material.writesToDepthBuffer = false
        sphere.materials = [material]
        let node = SCNNode(geometry: sphere)
        node.renderingOrder = 135
        return node
    }
}
