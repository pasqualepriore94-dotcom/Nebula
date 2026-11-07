import simd

// MARK: - Strutture condivise con gli shader (layout identico in Shaders.metal)

struct Vertex {
    var position: SIMD4<Float>
    var normal: SIMD4<Float>
}

struct MeshInstance {
    var model: float4x4
    var color: SIMD4<Float>      // rgb = colore base, a = intensità speculare
    var emissive: SIMD4<Float>   // rgb = colore emissivo/rim, a = intensità emissiva
}

struct Sprite {
    var posSize: SIMD4<Float>    // xyz = posizione, w = dimensione
    var color: SIMD4<Float>      // rgb = colore HDR, w = forma (0 bagliore, 1 anello)
    var dir: SIMD4<Float>        // xyz = direzione di allungamento, w = allungamento
}

struct Particle {
    var posLife: SIMD4<Float>    // xyz = posizione, w = vita residua
    var velMax: SIMD4<Float>     // xyz = velocità, w = vita iniziale
    var color: SIMD4<Float>      // rgb = colore HDR, w = dimensione
}

struct FrameUniforms {
    var viewProj: float4x4
    var view: float4x4
    var proj: float4x4
    var cameraPos: SIMD4<Float>
    var lightDir: SIMD4<Float>
    var params: SIMD4<Float>     // x tempo, y scorrimento, z aspect
    var post: SIMD4<Float>       // x flash danno, y aberrazione, z esposizione, w seme grana
}

// MARK: - Matrici

extension float4x4 {
    static func translation(_ t: SIMD3<Float>) -> float4x4 {
        var m = matrix_identity_float4x4
        m.columns.3 = SIMD4<Float>(t.x, t.y, t.z, 1)
        return m
    }

    static func scale(_ s: Float) -> float4x4 {
        return float4x4(diagonal: SIMD4<Float>(s, s, s, 1))
    }

    static func rotation(_ angle: Float, _ axis: SIMD3<Float>) -> float4x4 {
        return float4x4(simd_quatf(angle: angle, axis: normalize(axis)))
    }

    static func perspective(fovy: Float, aspect: Float, near: Float, far: Float) -> float4x4 {
        let ys = 1 / tanf(fovy * 0.5)
        let xs = ys / aspect
        let zs = far / (near - far)
        return float4x4(columns: (
            SIMD4<Float>(xs, 0, 0, 0),
            SIMD4<Float>(0, ys, 0, 0),
            SIMD4<Float>(0, 0, zs, -1),
            SIMD4<Float>(0, 0, zs * near, 0)
        ))
    }

    static func lookAt(eye: SIMD3<Float>, center: SIMD3<Float>, up: SIMD3<Float>) -> float4x4 {
        let z = normalize(eye - center)
        let x = normalize(cross(up, z))
        let y = cross(z, x)
        return float4x4(columns: (
            SIMD4<Float>(x.x, y.x, z.x, 0),
            SIMD4<Float>(x.y, y.y, z.y, 0),
            SIMD4<Float>(x.z, y.z, z.z, 0),
            SIMD4<Float>(-dot(x, eye), -dot(y, eye), -dot(z, eye), 1)
        ))
    }
}

// MARK: - Generatore casuale veloce (xorshift)

struct FastRNG {
    private var state: UInt64 = 0x9E37_79B9_7F4A_7C15

    init(seed: UInt64 = 0x9E37_79B9_7F4A_7C15) {
        state = seed == 0 ? 0x1234_5678 : seed
    }

    mutating func next() -> UInt64 {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return state
    }

    /// Numero casuale uniforme in [a, b]
    mutating func f(_ a: Float, _ b: Float) -> Float {
        let u = Float(next() >> 40) / Float(1 << 24)
        return a + (b - a) * u
    }

    mutating func unit3() -> SIMD3<Float> {
        let z = f(-1, 1)
        let t = f(0, 2 * Float.pi)
        let r = (max(0, 1 - z * z)).squareRoot()
        return SIMD3<Float>(r * cos(t), r * sin(t), z)
    }
}
