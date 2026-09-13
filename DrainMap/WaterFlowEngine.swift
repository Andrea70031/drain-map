import Foundation
import simd

struct WaterFlowEngine {
    func makeField(surface: SurfaceGeometrySnapshot) -> WaterFlowField {
        guard surface.isValid else { return .empty }
        let columns = surface.columns
        let rows = surface.rows
        let heights = surface.absoluteHeights
        let valid = surface.validMask

        var segments: [WaterFlowSegment3D] = []
        var pools: [WaterPool3D] = []
        segments.reserveCapacity((columns * rows) / 2)

        for row in stride(from: 1, to: rows - 1, by: 2) {
            for column in stride(from: 1, to: columns - 1, by: 2) {
                let index = row * columns + column
                guard valid[index], heights[index].isFinite else { continue }

                var bestIndex = index
                var bestHeight = heights[index]
                for dr in -1...1 {
                    for dc in -1...1 where !(dr == 0 && dc == 0) {
                        let nr = row + dr
                        let nc = column + dc
                        guard nr >= 0, nr < rows, nc >= 0, nc < columns else { continue }
                        let candidate = nr * columns + nc
                        guard valid[candidate], heights[candidate].isFinite else { continue }
                        if heights[candidate] < bestHeight {
                            bestHeight = heights[candidate]
                            bestIndex = candidate
                        }
                    }
                }

                if bestIndex != index {
                    let drop = max(heights[index] - bestHeight, 0)
                    guard drop >= 0.0005 else { continue }
                    let start = surface.vertices[index]
                    let end = surface.vertices[bestIndex]
                    let intensity = Float(min(max(drop / 0.012, 0.12), 1))
                    segments.append(WaterFlowSegment3D(start: start, end: end, intensity: intensity))
                } else {
                    let depression = surface.depressionGrid.indices.contains(index) ? surface.depressionGrid[index] : 0
                    if depression >= 3.0 {
                        let strength = Float(min(max(depression / 18.0, 0.2), 1))
                        let radius = 0.045 + strength * 0.08
                        pools.append(WaterPool3D(center: surface.vertices[index], radius: radius, strength: strength))
                    }
                }
            }
        }

        let mainPath = makeMainPath(surface: surface)
        let sortedPools = pools.sorted { $0.strength > $1.strength }
        return WaterFlowField(
            segments: Array(segments.prefix(260)),
            pools: Array(sortedPools.prefix(16)),
            mainPath: mainPath
        )
    }

    private func makeMainPath(surface: SurfaceGeometrySnapshot) -> [SIMD3<Float>] {
        let columns = surface.columns
        let rows = surface.rows
        let heights = surface.absoluteHeights
        let valid = surface.validMask
        let validIndices = valid.indices.filter { valid[$0] && heights[$0].isFinite }
        guard let start = validIndices.max(by: { heights[$0] < heights[$1] }) else { return [] }

        var current = start
        var visited = Set<Int>()
        var result: [SIMD3<Float>] = []

        for _ in 0..<(max(columns, rows) * 3) {
            guard !visited.contains(current) else { break }
            visited.insert(current)
            result.append(surface.vertices[current])

            let row = current / columns
            let column = current % columns
            var next = current
            var best = heights[current]

            for dr in -1...1 {
                for dc in -1...1 where !(dr == 0 && dc == 0) {
                    let nr = row + dr
                    let nc = column + dc
                    guard nr >= 0, nr < rows, nc >= 0, nc < columns else { continue }
                    let candidate = nr * columns + nc
                    guard valid[candidate], heights[candidate].isFinite else { continue }
                    if heights[candidate] < best - 0.0005 {
                        best = heights[candidate]
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
