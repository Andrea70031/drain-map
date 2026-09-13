import Foundation
import simd

struct SurfaceReconstructionEngine {
    private struct LocalPoint {
        let world: SIMD3<Float>
        let u: Float
        let v: Float
    }

    private struct Plane {
        let a: Float
        let b: Float
        let c: Float

        func height(u: Float, v: Float) -> Float {
            a * u + b * v + c
        }
    }

    let columns: Int
    let rows: Int

    init(columns: Int = 37, rows: Int = 29) {
        self.columns = max(columns, 12)
        self.rows = max(rows, 10)
    }

    func reconstruct(
        points allPoints: [SIMD3<Float>],
        cameraTransform: simd_float4x4,
        averageDepth: Double,
        meshAnchorCount: Int,
        pointLimit: Int
    ) -> SurfaceGeometrySnapshot? {
        guard allPoints.count >= 180 else { return nil }

        let points = downsample(allPoints, limit: max(pointLimit, 500))
        guard let band = dominantHorizontalBand(points), band.count >= 150 else { return nil }

        var right = SIMD3<Float>(cameraTransform.columns.0.x, 0, cameraTransform.columns.0.z)
        var forward = SIMD3<Float>(-cameraTransform.columns.2.x, 0, -cameraTransform.columns.2.z)
        if simd_length(right) < 0.001 { right = SIMD3<Float>(1, 0, 0) }
        if simd_length(forward) < 0.001 { forward = SIMD3<Float>(0, 0, -1) }
        right = simd_normalize(right)
        forward = simd_normalize(forward)

        let origin = band.reduce(SIMD3<Float>(repeating: 0), +) / Float(band.count)
        var local = band.map { point -> LocalPoint in
            let horizontal = SIMD3<Float>(point.x - origin.x, 0, point.z - origin.z)
            return LocalPoint(
                world: point,
                u: simd_dot(horizontal, right),
                v: simd_dot(horizontal, forward)
            )
        }

        guard let firstPlane = fitPlane(local) else { return nil }
        let residuals = local.map { Double($0.world.y - firstPlane.height(u: $0.u, v: $0.v)) }
        let residualMedian = median(residuals)
        let residualMAD = median(residuals.map { abs($0 - residualMedian) })
        let residualLimit = Float(min(0.075, max(0.012, residualMAD * 4.5 + 0.007)))

        local = local.filter {
            abs(Double($0.world.y - firstPlane.height(u: $0.u, v: $0.v)) - residualMedian) <= Double(residualLimit)
        }
        guard local.count >= 140, let plane = fitPlane(local) else { return nil }

        let uValues = local.map { Double($0.u) }
        let vValues = local.map { Double($0.v) }
        var uMin = Float(quantile(uValues, 0.015))
        var uMax = Float(quantile(uValues, 0.985))
        var vMin = Float(quantile(vValues, 0.015))
        var vMax = Float(quantile(vValues, 0.985))

        guard uMax > uMin, vMax > vMin else { return nil }
        enforceMinimumSpan(minimum: 0.35, minValue: &uMin, maxValue: &uMax)
        enforceMinimumSpan(minimum: 0.35, minValue: &vMin, maxValue: &vMax)

        let count = columns * rows
        var sums = Array(repeating: 0.0, count: count)
        var counts = Array(repeating: 0, count: count)

        for point in local {
            guard point.u >= uMin, point.u <= uMax, point.v >= vMin, point.v <= vMax else { continue }
            let nx = Double((point.u - uMin) / max(uMax - uMin, 0.0001))
            let ny = Double((point.v - vMin) / max(vMax - vMin, 0.0001))
            let column = min(max(Int(round(nx * Double(columns - 1))), 0), columns - 1)
            let row = min(max(Int(round(ny * Double(rows - 1))), 0), rows - 1)
            let index = row * columns + column
            sums[index] += Double(point.world.y)
            counts[index] += 1
        }

        let observedCells = counts.filter { $0 > 0 }.count
        let component = largestConnectedComponent(counts: counts)
        guard component.count >= max(40, count / 18) else { return nil }

        var heights = Array<Double?>(repeating: nil, count: count)
        for index in component where counts[index] > 0 {
            heights[index] = sums[index] / Double(counts[index])
        }

        let observedComponentCount = component.count
        fillShortGaps(&heights, maxGap: 3)
        interpolateHoles(&heights, passes: 5)
        smooth(&heights, passes: 2)

        let validHeights = heights.compactMap { $0 }
        guard validHeights.count >= 50 else { return nil }

        let robustMin = quantile(validHeights, 0.015)
        let robustMax = quantile(validHeights, 0.985)
        let meanHeight = validHeights.reduce(0, +) / Double(validHeights.count)
        let span = max(robustMax - robustMin, 0.002)

        var normalized = Array(repeating: Float(0.5), count: count)
        var absolute = Array(repeating: Double.nan, count: count)
        var validMask = Array(repeating: false, count: count)
        var vertices = Array(repeating: SIMD3<Float>(repeating: 0), count: count)

        for row in 0..<rows {
            let v = vMin + Float(row) / Float(max(rows - 1, 1)) * (vMax - vMin)
            for column in 0..<columns {
                let index = row * columns + column
                guard let measured = heights[index] else { continue }
                let u = uMin + Float(column) / Float(max(columns - 1, 1)) * (uMax - uMin)
                let clamped = min(max(measured, robustMin), robustMax)
                normalized[index] = Float((clamped - robustMin) / span)
                absolute[index] = measured
                validMask[index] = true
                var position = origin + right * u + forward * v
                position.y = Float(measured) + 0.0035
                vertices[index] = position
            }
        }

        let du = Double(uMax - uMin) / Double(max(columns - 1, 1))
        let dv = Double(vMax - vMin) / Double(max(rows - 1, 1))
        let localSlope = makeLocalSlopeGrid(heights: heights, du: du, dv: dv)

        var depressionGrid = Array(repeating: -1.0, count: count)
        var maxDepression = 0.0
        for row in 0..<rows {
            let v = vMin + Float(row) / Float(max(rows - 1, 1)) * (vMax - vMin)
            for column in 0..<columns {
                let index = row * columns + column
                guard let measured = heights[index] else { continue }
                let u = uMin + Float(column) / Float(max(columns - 1, 1)) * (uMax - uMin)
                let expected = Double(plane.height(u: u, v: v))
                let depression = max(0, (expected - measured) * 1000)
                depressionGrid[index] = depression
                maxDepression = max(maxDepression, depression)
            }
        }

        let triangles = makeTriangleIndices(validMask: validMask)
        guard triangles.count >= 6 else { return nil }

        let validIndices = validMask.indices.filter { validMask[$0] }
        guard let lowIndex = validIndices.min(by: { absolute[$0] < absolute[$1] }) else { return nil }
        let lowColumn = lowIndex % columns
        let lowRow = lowIndex / columns

        let gradient = sqrt(Double(plane.a * plane.a + plane.b * plane.b))
        let downhillAngle = atan2(Double(-plane.a), Double(-plane.b))
        let coverage = Double(observedComponentCount) / Double(count)
        let connectedRatio = observedCells > 0 ? Double(observedComponentCount) / Double(observedCells) : 0

        var gridForMetrics = Array(repeating: -1.0, count: count)
        for index in validIndices { gridForMetrics[index] = Double(normalized[index]) }

        var metrics = ScanMetrics()
        metrics.slopePercent = gradient * 100
        metrics.slopeDegrees = atan(gradient) * 180 / .pi
        metrics.distanceMeters = averageDepth
        metrics.downhillAngleRadians = downhillAngle
        metrics.sampleCount = local.count
        metrics.hasMeasurement = true
        metrics.surfaceGrid = gridForMetrics
        metrics.gridColumns = columns
        metrics.gridRows = rows
        metrics.lowPointX = Double(lowColumn) / Double(max(columns - 1, 1))
        metrics.lowPointY = Double(lowRow) / Double(max(rows - 1, 1))
        metrics.reliefMillimeters = span * 1000
        metrics.depressionMillimeters = maxDepression
        metrics.flowPath = makeFlowPath(absoluteHeights: absolute, validMask: validMask)
        metrics.coverage = coverage
        metrics.meshAnchorCount = meshAnchorCount
        metrics.minimumHeightMillimeters = (robustMin - meanHeight) * 1000
        metrics.maximumHeightMillimeters = (robustMax - meanHeight) * 1000
        metrics.localSlopeGrid = localSlope
        metrics.depressionGrid = depressionGrid

        return SurfaceGeometrySnapshot(
            columns: columns,
            rows: rows,
            vertices: vertices,
            validMask: validMask,
            normalizedHeights: normalized,
            absoluteHeights: absolute,
            localSlopeGrid: localSlope,
            depressionGrid: depressionGrid,
            triangleIndices: triangles,
            origin: origin,
            right: right,
            forward: forward,
            uMin: uMin,
            uMax: uMax,
            vMin: vMin,
            vMax: vMax,
            residualMADMillimeters: residualMAD * 1000,
            connectedCoverage: connectedRatio,
            metrics: metrics
        )
    }

    private func downsample(_ points: [SIMD3<Float>], limit: Int) -> [SIMD3<Float>] {
        guard points.count > limit else { return points }
        let strideValue = max(points.count / limit, 1)
        return Array(points.enumerated().compactMap { index, point in
            index.isMultiple(of: strideValue) ? point : nil
        }.prefix(limit))
    }

    private func dominantHorizontalBand(_ points: [SIMD3<Float>]) -> [SIMD3<Float>]? {
        guard !points.isEmpty else { return nil }
        let binSize: Float = 0.04
        var histogram: [Int: Int] = [:]
        for point in points {
            histogram[Int(floor(point.y / binSize)), default: 0] += 1
        }
        guard let mode = histogram.max(by: { $0.value < $1.value })?.key else { return nil }
        let center = (Float(mode) + 0.5) * binSize
        var selected = points.filter { abs($0.y - center) <= 0.16 }
        if selected.count < 150 {
            let medianY = Float(median(points.map { Double($0.y) }))
            selected = points.filter { abs($0.y - medianY) <= 0.24 }
        }
        return selected
    }

    private func fitPlane(_ points: [LocalPoint]) -> Plane? {
        guard points.count >= 3 else { return nil }
        var suu: Float = 0
        var suv: Float = 0
        var su: Float = 0
        var svv: Float = 0
        var sv: Float = 0
        var suy: Float = 0
        var svy: Float = 0
        var sy: Float = 0

        for point in points {
            suu += point.u * point.u
            suv += point.u * point.v
            su += point.u
            svv += point.v * point.v
            sv += point.v
            suy += point.u * point.world.y
            svy += point.v * point.world.y
            sy += point.world.y
        }

        let matrix = simd_float3x3(
            SIMD3<Float>(suu, suv, su),
            SIMD3<Float>(suv, svv, sv),
            SIMD3<Float>(su, sv, Float(points.count))
        )
        let determinant = simd_determinant(matrix)
        guard determinant.isFinite, abs(determinant) > 0.0000001 else { return nil }
        let solution = simd_inverse(matrix) * SIMD3<Float>(suy, svy, sy)
        guard solution.x.isFinite, solution.y.isFinite, solution.z.isFinite else { return nil }
        return Plane(a: solution.x, b: solution.y, c: solution.z)
    }

    private func enforceMinimumSpan(minimum: Float, minValue: inout Float, maxValue: inout Float) {
        guard maxValue - minValue < minimum else { return }
        let center = (minValue + maxValue) / 2
        minValue = center - minimum / 2
        maxValue = center + minimum / 2
    }

    private func largestConnectedComponent(counts: [Int]) -> Set<Int> {
        var visited = Set<Int>()
        var best = Set<Int>()

        for start in counts.indices where counts[start] > 0 && !visited.contains(start) {
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
                let neighbors = [(column - 1, row), (column + 1, row), (column, row - 1), (column, row + 1)]
                for (nc, nr) in neighbors {
                    guard nc >= 0, nc < columns, nr >= 0, nr < rows else { continue }
                    let next = nr * columns + nc
                    guard counts[next] > 0, !visited.contains(next) else { continue }
                    visited.insert(next)
                    queue.append(next)
                }
            }
            if component.count > best.count { best = component }
        }
        return best
    }

    private func fillShortGaps(_ heights: inout [Double?], maxGap: Int) {
        guard columns > 2, rows > 2 else { return }
        for row in 0..<rows {
            for column in 1..<(columns - 1) {
                let index = row * columns + column
                guard heights[index] == nil else { continue }
                for gap in 1...maxGap {
                    let left = column - gap
                    let right = column + gap
                    guard left >= 0, right < columns else { continue }
                    if let a = heights[row * columns + left], let b = heights[row * columns + right] {
                        heights[index] = (a + b) / 2
                        break
                    }
                }
            }
        }
        for column in 0..<columns {
            for row in 1..<(rows - 1) {
                let index = row * columns + column
                guard heights[index] == nil else { continue }
                for gap in 1...maxGap {
                    let top = row - gap
                    let bottom = row + gap
                    guard top >= 0, bottom < rows else { continue }
                    if let a = heights[top * columns + column], let b = heights[bottom * columns + column] {
                        heights[index] = (a + b) / 2
                        break
                    }
                }
            }
        }
    }

    private func interpolateHoles(_ heights: inout [Double?], passes: Int) {
        for _ in 0..<passes {
            let source = heights
            var changed = false
            for row in 0..<rows {
                for column in 0..<columns {
                    let index = row * columns + column
                    guard source[index] == nil else { continue }
                    var neighbors: [Double] = []
                    for dr in -1...1 {
                        for dc in -1...1 where !(dr == 0 && dc == 0) {
                            let nr = row + dr
                            let nc = column + dc
                            guard nr >= 0, nr < rows, nc >= 0, nc < columns else { continue }
                            if let value = source[nr * columns + nc] { neighbors.append(value) }
                        }
                    }
                    if neighbors.count >= 5 {
                        heights[index] = neighbors.reduce(0, +) / Double(neighbors.count)
                        changed = true
                    }
                }
            }
            if !changed { break }
        }
    }

    private func smooth(_ heights: inout [Double?], passes: Int) {
        for _ in 0..<passes {
            let source = heights
            for row in 0..<rows {
                for column in 0..<columns {
                    let index = row * columns + column
                    guard let center = source[index] else { continue }
                    var weighted = center * 4
                    var weight = 4.0
                    for dr in -1...1 {
                        for dc in -1...1 where !(dr == 0 && dc == 0) {
                            let nr = row + dr
                            let nc = column + dc
                            guard nr >= 0, nr < rows, nc >= 0, nc < columns,
                                  let value = source[nr * columns + nc] else { continue }
                            weighted += value
                            weight += 1
                        }
                    }
                    heights[index] = weighted / weight
                }
            }
        }
    }

    private func makeLocalSlopeGrid(heights: [Double?], du: Double, dv: Double) -> [Double] {
        var result = Array(repeating: -1.0, count: heights.count)
        guard du > 0.0001, dv > 0.0001 else { return result }
        for row in 0..<rows {
            for column in 0..<columns {
                let index = row * columns + column
                guard heights[index] != nil else { continue }
                let left = column > 0 ? heights[row * columns + column - 1] : nil
                let right = column + 1 < columns ? heights[row * columns + column + 1] : nil
                let top = row > 0 ? heights[(row - 1) * columns + column] : nil
                let bottom = row + 1 < rows ? heights[(row + 1) * columns + column] : nil
                var dx = 0.0
                var dy = 0.0
                var hasAxis = false
                if let left, let right {
                    dx = (right - left) / (2 * du)
                    hasAxis = true
                }
                if let top, let bottom {
                    dy = (bottom - top) / (2 * dv)
                    hasAxis = true
                }
                if hasAxis { result[index] = sqrt(dx * dx + dy * dy) * 100 }
            }
        }
        return result
    }

    private func makeTriangleIndices(validMask: [Bool]) -> [UInt32] {
        var indices: [UInt32] = []
        indices.reserveCapacity((columns - 1) * (rows - 1) * 6)
        for row in 0..<(rows - 1) {
            for column in 0..<(columns - 1) {
                let a = row * columns + column
                let b = a + 1
                let c = a + columns
                let d = c + 1
                if validMask[a], validMask[b], validMask[c] {
                    indices.append(contentsOf: [UInt32(a), UInt32(c), UInt32(b)])
                }
                if validMask[b], validMask[c], validMask[d] {
                    indices.append(contentsOf: [UInt32(b), UInt32(c), UInt32(d)])
                }
            }
        }
        return indices
    }

    private func makeFlowPath(absoluteHeights: [Double], validMask: [Bool]) -> [SurfacePoint] {
        let valid = validMask.indices.filter { validMask[$0] && absoluteHeights[$0].isFinite }
        guard let start = valid.max(by: { absoluteHeights[$0] < absoluteHeights[$1] }) else { return [] }
        var current = start
        var visited = Set<Int>()
        var path: [SurfacePoint] = []

        for _ in 0..<(max(columns, rows) * 3) {
            guard !visited.contains(current) else { break }
            visited.insert(current)
            let row = current / columns
            let column = current % columns
            path.append(SurfacePoint(
                x: Double(column) / Double(max(columns - 1, 1)),
                y: Double(row) / Double(max(rows - 1, 1))
            ))

            var next = current
            var best = absoluteHeights[current]
            for dr in -1...1 {
                for dc in -1...1 where !(dr == 0 && dc == 0) {
                    let nr = row + dr
                    let nc = column + dc
                    guard nr >= 0, nr < rows, nc >= 0, nc < columns else { continue }
                    let candidate = nr * columns + nc
                    guard validMask[candidate] else { continue }
                    let value = absoluteHeights[candidate]
                    if value < best - 0.0008 {
                        best = value
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
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
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
