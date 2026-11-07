import simd

/// Costruisce mesh low-poly con normali piatte (look sfaccettato).
final class MeshBuilder {
    private(set) var vertices: [Vertex] = []

    func tri(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) {
        var n = cross(b - a, c - a)
        let len = length(n)
        if len < 1e-6 { return }
        n /= len
        let nn = SIMD4<Float>(n.x, n.y, n.z, 0)
        vertices.append(Vertex(position: SIMD4<Float>(a.x, a.y, a.z, 1), normal: nn))
        vertices.append(Vertex(position: SIMD4<Float>(b.x, b.y, b.z, 1), normal: nn))
        vertices.append(Vertex(position: SIMD4<Float>(c.x, c.y, c.z, 1), normal: nn))
    }

    func octa(_ c: SIMD3<Float>, _ r: SIMD3<Float>) {
        let px = c + SIMD3<Float>(r.x, 0, 0)
        let nx = c - SIMD3<Float>(r.x, 0, 0)
        let py = c + SIMD3<Float>(0, r.y, 0)
        let ny = c - SIMD3<Float>(0, r.y, 0)
        let pz = c + SIMD3<Float>(0, 0, r.z)
        let nz = c - SIMD3<Float>(0, 0, r.z)
        tri(py, px, pz); tri(py, pz, nx); tri(py, nx, nz); tri(py, nz, px)
        tri(ny, pz, px); tri(ny, nx, pz); tri(ny, nz, nx); tri(ny, px, nz)
    }

    func tetra(_ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>, _ d: SIMD3<Float>) {
        tri(a, b, c); tri(a, c, d); tri(a, d, b); tri(b, d, c)
    }
}

enum Meshes {
    /// Caccia del giocatore, punta verso +Y.
    static func player() -> [Vertex] {
        let b = MeshBuilder()
        let nose = SIMD3<Float>(0, 1.45, 0)
        let top = SIMD3<Float>(0, -0.15, 0.38)
        let bot = SIMD3<Float>(0, -0.15, -0.22)
        let tail = SIMD3<Float>(0, -0.85, 0.12)
        let sides: [Float] = [-1, 1]
        for s in sides {
            let body = SIMD3<Float>(0.38 * s, -0.35, 0)
            let wing = SIMD3<Float>(1.4 * s, -0.95, -0.02)
            let wingBack = SIMD3<Float>(0.55 * s, -0.82, 0)
            let wingTop = SIMD3<Float>(0.72 * s, -0.62, 0.11)
            let fin = SIMD3<Float>(0.52 * s, -1.08, 0.52)
            let finBase = SIMD3<Float>(0.46 * s, -0.55, 0.06)
            b.tri(nose, top, body)
            b.tri(nose, bot, body)
            b.tri(top, body, tail)
            b.tri(bot, body, tail)
            b.tri(body, wing, wingTop)
            b.tri(wing, wingBack, wingTop)
            b.tri(wingBack, body, wingTop)
            b.tri(body, wing, wingBack)
            b.tri(wingBack, fin, finBase)
        }
        // abitacolo e ugello
        b.octa(SIMD3<Float>(0, 0.25, 0.28), SIMD3<Float>(0.15, 0.45, 0.13))
        b.octa(SIMD3<Float>(0, -0.85, 0.05), SIMD3<Float>(0.24, 0.13, 0.19))
        return b.vertices
    }

    /// Caccia nemico, punta verso +Y (viene ruotato di 180°).
    static func fighter() -> [Vertex] {
        let b = MeshBuilder()
        b.octa(.zero, SIMD3<Float>(0.45, 0.95, 0.4))
        let sides: [Float] = [-1, 1]
        for s in sides {
            b.octa(SIMD3<Float>(1.0 * s, -0.1, 0), SIMD3<Float>(0.5, 0.55, 0.09))
            b.octa(SIMD3<Float>(0.5 * s, 0, 0), SIMD3<Float>(0.5, 0.12, 0.1))
            b.octa(SIMD3<Float>(1.0 * s, 0.5, 0.05), SIMD3<Float>(0.08, 0.4, 0.08))
        }
        return b.vertices
    }

    /// Drone kamikaze: ottaedro stellato.
    static func drone() -> [Vertex] {
        let b = MeshBuilder()
        let k: Float = 0.75
        let a1 = SIMD3<Float>(1, 1, 1) * k
        let a2 = SIMD3<Float>(1, -1, -1) * k
        let a3 = SIMD3<Float>(-1, 1, -1) * k
        let a4 = SIMD3<Float>(-1, -1, 1) * k
        b.tetra(a1, a2, a3, a4)
        b.tetra(-a1, -a2, -a3, -a4)
        b.octa(.zero, SIMD3<Float>(0.55, 0.55, 0.55))
        return b.vertices
    }

    /// Asteroide: icosfera suddivisa e deformata.
    static func asteroid() -> [Vertex] {
        let t: Float = (1 + Float(5).squareRoot()) / 2
        var pts: [SIMD3<Float>] = [
            SIMD3<Float>(-1, t, 0), SIMD3<Float>(1, t, 0), SIMD3<Float>(-1, -t, 0), SIMD3<Float>(1, -t, 0),
            SIMD3<Float>(0, -1, t), SIMD3<Float>(0, 1, t), SIMD3<Float>(0, -1, -t), SIMD3<Float>(0, 1, -t),
            SIMD3<Float>(t, 0, -1), SIMD3<Float>(t, 0, 1), SIMD3<Float>(-t, 0, -1), SIMD3<Float>(-t, 0, 1)
        ]
        pts = pts.map { normalize($0) }
        var faces: [[Int]] = [
            [0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11],
            [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6], [7, 1, 8],
            [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9],
            [4, 9, 5], [2, 4, 11], [6, 2, 10], [8, 6, 7], [9, 8, 1]
        ]

        for _ in 0..<2 {
            var cache: [UInt64: Int] = [:]
            func mid(_ i: Int, _ j: Int) -> Int {
                let a = UInt64(min(i, j)), b = UInt64(max(i, j))
                let key = (a << 32) | b
                if let idx = cache[key] { return idx }
                pts.append(normalize((pts[i] + pts[j]) * 0.5))
                cache[key] = pts.count - 1
                return pts.count - 1
            }
            var next: [[Int]] = []
            next.reserveCapacity(faces.count * 4)
            for f in faces {
                let a = mid(f[0], f[1]), b = mid(f[1], f[2]), c = mid(f[2], f[0])
                next.append([f[0], a, c])
                next.append([f[1], b, a])
                next.append([f[2], c, b])
                next.append([a, b, c])
            }
            faces = next
        }

        // deformazione deterministica
        let displaced: [SIMD3<Float>] = pts.map { p in
            var r: Float = 1
            r += 0.22 * sin(p.x * 5.1 + 1.3) * sin(p.y * 4.3 + 2.1) * sin(p.z * 6.2 + 0.7)
            r += 0.09 * sin(p.x * 13.0 + p.y * 11.0 + 0.5)
            r += 0.05 * sin(p.z * 21.0 - p.x * 17.0)
            return p * r
        }

        let b = MeshBuilder()
        for f in faces {
            b.tri(displaced[f[0]], displaced[f[1]], displaced[f[2]])
        }
        return b.vertices
    }
}
