import Foundation
import simd

enum MeshKind: Int, CaseIterable {
    case player = 0, fighter, drone, asteroid
}

enum EnemyKind { case fighter, drone, asteroid }
enum GameState { case title, playing, gameOver }
enum HapticEvent { case kill, hurt, pickup, gameOver }

struct Enemy {
    var kind: EnemyKind
    var pos: SIMD2<Float>
    var vel: SIMD2<Float>
    var hp: Int
    var radius: Float
    var scale: Float
    var axis: SIMD3<Float>
    var spin: Float
    var fireTimer: Float
    var phase: Float
    var angle: Float = 0
    var flash: Float = 0
    var age: Float = 0
    var alive = true
}

struct Bullet {
    var pos: SIMD2<Float>
    var vel: SIMD2<Float>
    var hostile: Bool
    var alive = true
}

struct Pickup {
    var pos: SIMD2<Float>
    var t: Float = 0
    var alive = true
}

struct Shockwave {
    var pos: SIMD2<Float>
    var duration: Float
    var size: Float
    var color: SIMD3<Float>
    var t: Float = 0
}

/// Dati di un fotogramma consegnati al renderer.
struct FrameData {
    var instances: [[MeshInstance]] = Array(repeating: [], count: MeshKind.allCases.count)
    var sprites: [Sprite] = []
    var shake = SIMD2<Float>(0, 0)
    var flash: Float = 0
    var aberration: Float = 0
    var time: Float = 0
    var scroll: Float = 0
}

final class Game {
    private(set) var state: GameState = .title
    private(set) var score = 0
    private(set) var best: Int
    private(set) var lives = 3

    var onHUD: (() -> Void)?
    var onHaptic: ((HapticEvent) -> Void)?

    /// Particelle da creare questo fotogramma (le simula la GPU).
    var particleSpawns: [Particle] = []
    let maxSpawns = 16000

    private var rng = FastRNG(seed: UInt64(Date().timeIntervalSince1970 * 1000))
    private var playerPos = SIMD2<Float>(0, -7)
    private var targetPos = SIMD2<Float>(0, -7)
    private var bank: Float = 0
    private var invuln: Float = 0
    private var fireCD: Float = 0
    private var triple: Float = 0
    private var time: Float = 0
    private var playTime: Float = 0
    private var gameOverAt: Float = -10
    private var spawnTimer: Float = 1
    private var scroll: Float = 0
    private var shake: Float = 0
    private var damageFlash: Float = 0

    private var enemies: [Enemy] = []
    private var bullets: [Bullet] = []
    private var pickups: [Pickup] = []
    private var shockwaves: [Shockwave] = []

    let minX: Float = -5.2, maxX: Float = 5.2, minY: Float = -11, maxY: Float = 8

    init() {
        best = UserDefaults.standard.integer(forKey: "nebula.best")
        particleSpawns.reserveCapacity(maxSpawns)
        enemies.reserveCapacity(128)
        bullets.reserveCapacity(512)
    }

    // MARK: - Input

    func tap() {
        switch state {
        case .title: start()
        case .gameOver: if time - gameOverAt > 1.2 { start() }
        case .playing: break
        }
    }

    func drag(by d: SIMD2<Float>) {
        guard state == .playing else { return }
        targetPos += d
        targetPos.x = min(max(targetPos.x, minX), maxX)
        targetPos.y = min(max(targetPos.y, minY), maxY)
    }

    private func start() {
        state = .playing
        score = 0
        lives = 3
        invuln = 2
        triple = 0
        playTime = 0
        spawnTimer = 1
        enemies.removeAll(keepingCapacity: true)
        bullets.removeAll(keepingCapacity: true)
        pickups.removeAll(keepingCapacity: true)
        playerPos = SIMD2<Float>(0, -7)
        targetPos = playerPos
        onHUD?()
    }

    // MARK: - Aggiornamento

    func update(dt: Float) {
        time += dt
        let speed: Float = state == .playing ? 1 + min(playTime / 90, 1.5) : 0.6
        scroll += dt * 6 * speed
        shake = max(0, shake - dt * 2.5)
        damageFlash = max(0, damageFlash - dt * 2)

        for i in shockwaves.indices { shockwaves[i].t += dt }
        shockwaves.removeAll { $0.t >= $0.duration }

        switch state {
        case .playing: updatePlaying(dt)
        case .title: updateTitle(dt)
        case .gameOver: updateAttract(dt)
        }

        updateEnemies(dt, active: state == .playing)
        updateBullets(dt)
        if state == .playing { collide() }

        enemies.removeAll { !$0.alive }
        bullets.removeAll { !$0.alive }
        pickups.removeAll { !$0.alive }
    }

    private func updateTitle(_ dt: Float) {
        targetPos = SIMD2<Float>(sin(time * 0.8) * 2.5, -6 + sin(time * 1.3) * 0.8)
        movePlayer(dt)
        engineTrail(dt)
        updateAttract(dt)
    }

    private func updateAttract(_ dt: Float) {
        spawnTimer -= dt
        if spawnTimer <= 0 {
            spawnTimer = rng.f(0.8, 1.6)
            spawnAsteroid(difficulty: 0)
        }
    }

    private func updatePlaying(_ dt: Float) {
        playTime += dt
        invuln = max(0, invuln - dt)
        triple = max(0, triple - dt)
        movePlayer(dt)

        fireCD -= dt
        if fireCD <= 0 {
            fireCD = 0.085
            let nose = playerPos + SIMD2<Float>(0, 1.4)
            bullets.append(Bullet(pos: nose, vel: SIMD2<Float>(0, 34), hostile: false))
            if triple > 0 {
                let angles: [Float] = [-0.14, 0.14]
                for a in angles {
                    bullets.append(Bullet(pos: nose, vel: SIMD2<Float>(sin(a) * 34, cos(a) * 34), hostile: false))
                }
            }
            for _ in 0..<8 {
                emit(SIMD3<Float>(nose.x, nose.y, 0),
                     vel: SIMD3<Float>(rng.f(-3, 3), rng.f(4, 12), rng.f(-2, 2)),
                     life: rng.f(0.06, 0.16),
                     color: SIMD3<Float>(0.5, 1.8, 3.5),
                     size: 0.1)
            }
        }

        engineTrail(dt)

        spawnTimer -= dt
        if spawnTimer <= 0 {
            let d = playTime / 60
            spawnTimer = max(0.22, 1.0 - d * 0.3) * rng.f(0.6, 1.2)
            spawnEnemy(difficulty: d)
        }
    }

    private func movePlayer(_ dt: Float) {
        let prev = playerPos
        playerPos += (targetPos - playerPos) * min(1, dt * 22)
        let vx = (playerPos.x - prev.x) / max(dt, 1e-4)
        let targetBank = min(max(-vx * 0.07, -0.9), 0.9)
        bank += (targetBank - bank) * min(1, dt * 10)
    }

    private func engineTrail(_ dt: Float) {
        let n = Int(dt * 4500) + 1
        let base = SIMD3<Float>(playerPos.x, playerPos.y - 0.95, 0.05)
        for _ in 0..<n {
            let side = rng.f(-0.18, 0.18)
            let p = base + SIMD3<Float>(side * cos(bank), 0, -side * sin(bank))
            emit(p,
                 vel: SIMD3<Float>(rng.f(-0.7, 0.7), rng.f(-13, -7), rng.f(-0.7, 0.7)),
                 life: rng.f(0.15, 0.4),
                 color: SIMD3<Float>(0.3, 0.9, 3.4) * rng.f(0.7, 1.3),
                 size: rng.f(0.08, 0.16))
        }
    }

    // MARK: - Nemici

    private func spawnEnemy(difficulty d: Float) {
        let r = rng.f(0, 1)
        let droneChance = min(0.35, 0.1 + d * 0.12)
        if r < 0.4 {
            enemies.append(Enemy(kind: .fighter,
                                 pos: SIMD2<Float>(rng.f(-4.5, 4.5), 21),
                                 vel: SIMD2<Float>(0, -(3.2 + d)),
                                 hp: 2, radius: 1.15, scale: 1,
                                 axis: SIMD3<Float>(0, 1, 0), spin: 0,
                                 fireTimer: rng.f(0.8, 1.8), phase: rng.f(0, 6.28)))
        } else if r < 0.4 + droneChance {
            enemies.append(Enemy(kind: .drone,
                                 pos: SIMD2<Float>(rng.f(-5.5, 5.5), 21),
                                 vel: SIMD2<Float>(0, -6),
                                 hp: 1, radius: 0.85, scale: 0.8,
                                 axis: rng.unit3(), spin: rng.f(3, 6),
                                 fireTimer: 0, phase: 0))
        } else {
            spawnAsteroid(difficulty: d)
        }
    }

    private func spawnAsteroid(difficulty d: Float) {
        let s = rng.f(0.9, 1.9)
        enemies.append(Enemy(kind: .asteroid,
                             pos: SIMD2<Float>(rng.f(-6, 6), 21),
                             vel: SIMD2<Float>(rng.f(-1, 1), -rng.f(2.5, 4.5) - d * 0.5),
                             hp: max(1, Int(s * 3)), radius: s * 1.05, scale: s,
                             axis: rng.unit3(), spin: rng.f(0.4, 1.5),
                             fireTimer: 0, phase: 0))
    }

    private func updateEnemies(_ dt: Float, active: Bool) {
        for i in enemies.indices {
            var e = enemies[i]
            e.age += dt
            e.angle += e.spin * dt
            e.flash = max(0, e.flash - dt * 6)
            switch e.kind {
            case .fighter:
                e.vel.x = cos(time * 1.6 + e.phase) * 3.2
                if active {
                    e.fireTimer -= dt
                    if e.fireTimer <= 0 && e.pos.y < 16 && e.pos.y > playerPos.y + 3 {
                        e.fireTimer = rng.f(1.2, 2.2)
                        let to = playerPos - e.pos
                        let len = length(to)
                        if len > 0.01 {
                            bullets.append(Bullet(pos: e.pos - SIMD2<Float>(0, 0.9), vel: to / len * 11, hostile: true))
                        }
                    }
                }
            case .drone:
                if active && e.pos.y > playerPos.y - 1 && e.age < 10 {
                    let to = playerPos - e.pos
                    let len = length(to)
                    if len > 0.01 {
                        let desired = to / len * 8.5
                        e.vel += (desired - e.vel) * min(1, dt * 1.6)
                    }
                }
                emit(SIMD3<Float>(e.pos.x, e.pos.y, 0),
                     vel: SIMD3<Float>(rng.f(-1, 1), rng.f(-1, 1), rng.f(-1, 1)) - SIMD3<Float>(e.vel.x, e.vel.y, 0) * 0.3,
                     life: rng.f(0.2, 0.4),
                     color: SIMD3<Float>(2.6, 0.5, 2.8),
                     size: 0.12)
            case .asteroid:
                break
            }
            e.pos += e.vel * dt
            if e.pos.y < -16 || abs(e.pos.x) > 14 || e.age > 30 { e.alive = false }
            enemies[i] = e
        }
    }

    private func updateBullets(_ dt: Float) {
        for i in bullets.indices {
            bullets[i].pos += bullets[i].vel * dt
            let p = bullets[i].pos
            if p.y > 24 || p.y < -16 || abs(p.x) > 12 { bullets[i].alive = false }
        }
        for i in pickups.indices {
            pickups[i].t += dt
            pickups[i].pos.y -= 2.5 * dt
            pickups[i].pos.x += sin(pickups[i].t * 2) * dt
            if pickups[i].pos.y < -15 { pickups[i].alive = false }
        }
    }

    // MARK: - Collisioni

    private func collide() {
        for bi in bullets.indices where bullets[bi].alive && !bullets[bi].hostile {
            let bp = bullets[bi].pos
            for ei in enemies.indices where enemies[ei].alive {
                let d = bp - enemies[ei].pos
                let r = enemies[ei].radius
                if dot(d, d) < r * r {
                    bullets[bi].alive = false
                    enemies[ei].hp -= 1
                    enemies[ei].flash = 1
                    hitSparks(at: bp)
                    if enemies[ei].hp <= 0 { kill(ei) }
                    break
                }
            }
        }

        guard state == .playing else { return }

        for ei in enemies.indices where enemies[ei].alive {
            let d = playerPos - enemies[ei].pos
            let r = 0.6 + enemies[ei].radius * 0.85
            if dot(d, d) < r * r {
                kill(ei)
                if invuln <= 0 { hurtPlayer() }
                if state != .playing { return }
            }
        }

        if invuln <= 0 {
            for bi in bullets.indices where bullets[bi].alive && bullets[bi].hostile {
                let d = playerPos - bullets[bi].pos
                if dot(d, d) < 0.55 * 0.55 {
                    bullets[bi].alive = false
                    hurtPlayer()
                    break
                }
            }
        }

        for pi in pickups.indices where pickups[pi].alive {
            let d = playerPos - pickups[pi].pos
            if dot(d, d) < 1.3 * 1.3 {
                pickups[pi].alive = false
                triple = 10
                score += 250
                explode(at: pickups[pi].pos, color: SIMD3<Float>(0.4, 2.5, 1.6), count: 500, power: 6, ring: 3)
                onHaptic?(.pickup)
                onHUD?()
            }
        }
    }

    private func kill(_ i: Int) {
        let e = enemies[i]
        enemies[i].alive = false
        switch e.kind {
        case .fighter:
            score += 150
            explode(at: e.pos, color: SIMD3<Float>(3.0, 0.8, 0.35), count: 1200, power: 11, ring: 4)
        case .drone:
            score += 100
            explode(at: e.pos, color: SIMD3<Float>(2.6, 0.5, 2.8), count: 900, power: 9, ring: 3)
        case .asteroid:
            score += 60 * max(1, Int(e.scale * 2))
            explode(at: e.pos, color: SIMD3<Float>(2.2, 1.2, 0.5), count: Int(1000 * e.scale), power: 6 * e.scale + 3, ring: 3 * e.scale)
            // detriti rocciosi
            for _ in 0..<Int(300 * e.scale) {
                let dir = rng.unit3()
                emit(SIMD3<Float>(e.pos.x, e.pos.y, 0) + dir * e.scale * 0.6,
                     vel: dir * rng.f(1, 5) * e.scale,
                     life: rng.f(0.6, 1.6),
                     color: SIMD3<Float>(0.35, 0.3, 0.27),
                     size: rng.f(0.08, 0.2))
            }
        }
        if rng.f(0, 1) < 0.07 { pickups.append(Pickup(pos: e.pos)) }
        shake = min(1.5, shake + 0.25)
        onHaptic?(.kill)
        onHUD?()
    }

    private func hurtPlayer() {
        lives -= 1
        invuln = 2.5
        damageFlash = 1
        shake = min(1.6, shake + 1.0)
        explode(at: playerPos, color: SIMD3<Float>(0.4, 1.2, 3.0), count: 2500, power: 14, ring: 6)
        if lives <= 0 {
            state = .gameOver
            gameOverAt = time
            spawnTimer = 2
            explode(at: playerPos, color: SIMD3<Float>(3.0, 1.2, 0.4), count: 9000, power: 22, ring: 12)
            if score > best {
                best = score
                UserDefaults.standard.set(best, forKey: "nebula.best")
            }
            onHaptic?(.gameOver)
        } else {
            onHaptic?(.hurt)
        }
        onHUD?()
    }

    // MARK: - Effetti

    private func emit(_ p: SIMD3<Float>, vel: SIMD3<Float>, life: Float, color: SIMD3<Float>, size: Float) {
        guard particleSpawns.count < maxSpawns else { return }
        particleSpawns.append(Particle(posLife: SIMD4<Float>(p.x, p.y, p.z, life),
                                       velMax: SIMD4<Float>(vel.x, vel.y, vel.z, life),
                                       color: SIMD4<Float>(color.x, color.y, color.z, size)))
    }

    private func explode(at p: SIMD2<Float>, color: SIMD3<Float>, count: Int, power: Float, ring: Float) {
        let c = SIMD3<Float>(p.x, p.y, 0)
        let hot = SIMD3<Float>(3.5, 3.0, 2.5)
        for _ in 0..<count {
            let dir = rng.unit3()
            let u = rng.f(0, 1)
            let speed = power * (0.12 + 0.88 * u * u)
            let isHot = rng.f(0, 1) < 0.25
            emit(c + dir * rng.f(0, 0.3),
                 vel: dir * speed,
                 life: rng.f(0.35, 1.3),
                 color: isHot ? hot : color * rng.f(0.6, 1.4),
                 size: isHot ? rng.f(0.06, 0.12) : rng.f(0.08, 0.22))
        }
        shockwaves.append(Shockwave(pos: p, duration: 0.45, size: ring, color: color))
    }

    private func hitSparks(at p: SIMD2<Float>) {
        for _ in 0..<24 {
            let dir = rng.unit3()
            emit(SIMD3<Float>(p.x, p.y, 0), vel: dir * rng.f(3, 9) + SIMD3<Float>(0, 3, 0),
                 life: rng.f(0.1, 0.3), color: SIMD3<Float>(3, 2.4, 1.5), size: 0.08)
        }
    }

    // MARK: - Costruzione del fotogramma

    func buildFrame(_ f: inout FrameData) {
        for k in f.instances.indices { f.instances[k].removeAll(keepingCapacity: true) }
        f.sprites.removeAll(keepingCapacity: true)
        f.time = time
        f.scroll = scroll
        let s = shake * shake
        f.shake = SIMD2<Float>(rng.f(-1, 1), rng.f(-1, 1)) * s * 0.35
        f.flash = damageFlash
        f.aberration = min(1, shake * 0.6 + damageFlash)

        // giocatore
        if state != .gameOver {
            let blink = state == .playing && invuln > 0 && Int(time * 14) % 2 == 1
            if !blink {
                let model = float4x4.translation(SIMD3<Float>(playerPos.x, playerPos.y, 0))
                    * float4x4.rotation(bank, SIMD3<Float>(0, 1, 0))
                    * float4x4.rotation(-0.25, SIMD3<Float>(1, 0, 0))
                f.instances[MeshKind.player.rawValue].append(
                    MeshInstance(model: model,
                                 color: SIMD4<Float>(0.78, 0.82, 0.92, 1.0),
                                 emissive: SIMD4<Float>(0.2, 0.75, 1.6, 0.05)))
            }
            f.sprites.append(Sprite(posSize: SIMD4<Float>(playerPos.x, playerPos.y - 0.95, 0.05, 0.55 + 0.08 * sin(time * 40)),
                                    color: SIMD4<Float>(0.6, 1.6, 4.0, 0),
                                    dir: SIMD4<Float>(0, -1, 0, 0.7)))
            if state == .playing && invuln > 0 {
                f.sprites.append(Sprite(posSize: SIMD4<Float>(playerPos.x, playerPos.y, 0.2, 1.7),
                                        color: SIMD4<Float>(0.3, 1.0, 2.5, 1),
                                        dir: SIMD4<Float>(0, 1, 0, 0)))
            }
            if state == .playing && triple > 0 {
                f.sprites.append(Sprite(posSize: SIMD4<Float>(playerPos.x, playerPos.y + 1.3, 0.1, 0.35),
                                        color: SIMD4<Float>(0.4, 2.5, 1.6, 0),
                                        dir: SIMD4<Float>(0, 1, 0, 0)))
            }
        }

        // nemici
        for e in enemies {
            let t = float4x4.translation(SIMD3<Float>(e.pos.x, e.pos.y, 0))
            switch e.kind {
            case .fighter:
                let m = t * float4x4.rotation(sin(time * 1.6 + e.phase) * 0.5, SIMD3<Float>(0, 1, 0))
                    * float4x4.rotation(0.3, SIMD3<Float>(1, 0, 0))
                    * float4x4.rotation(.pi, SIMD3<Float>(0, 0, 1))
                f.instances[MeshKind.fighter.rawValue].append(
                    MeshInstance(model: m,
                                 color: SIMD4<Float>(0.75, 0.2, 0.25, 0.8),
                                 emissive: SIMD4<Float>(1.5, 0.35, 0.2, 0.15 + e.flash * 6)))
            case .drone:
                let m = t * float4x4.rotation(e.angle, e.axis) * float4x4.scale(e.scale)
                f.instances[MeshKind.drone.rawValue].append(
                    MeshInstance(model: m,
                                 color: SIMD4<Float>(0.35, 0.25, 0.5, 1.0),
                                 emissive: SIMD4<Float>(2.2, 0.4, 2.5, 0.4 + 0.3 * sin(time * 8) + e.flash * 6)))
            case .asteroid:
                let m = t * float4x4.rotation(e.angle, e.axis) * float4x4.scale(e.scale)
                f.instances[MeshKind.asteroid.rawValue].append(
                    MeshInstance(model: m,
                                 color: SIMD4<Float>(0.45, 0.4, 0.37, 0.25),
                                 emissive: SIMD4<Float>(1.0, 0.45, 0.2, e.flash * 4)))
            }
        }

        // proiettili
        for b in bullets {
            let len = max(length(b.vel), 0.001)
            if b.hostile {
                f.sprites.append(Sprite(posSize: SIMD4<Float>(b.pos.x, b.pos.y, 0, 0.3),
                                        color: SIMD4<Float>(4.0, 0.6, 1.8, 0),
                                        dir: SIMD4<Float>(b.vel.x / len, b.vel.y / len, 0, 1.0)))
            } else {
                f.sprites.append(Sprite(posSize: SIMD4<Float>(b.pos.x, b.pos.y, 0, 0.18),
                                        color: SIMD4<Float>(0.5, 1.8, 4.0, 0),
                                        dir: SIMD4<Float>(b.vel.x / len, b.vel.y / len, 0, 4.0)))
            }
        }

        // potenziamenti
        for p in pickups {
            let pulse = 1 + 0.15 * sin(p.t * 8)
            f.sprites.append(Sprite(posSize: SIMD4<Float>(p.pos.x, p.pos.y, 0, 0.6 * pulse),
                                    color: SIMD4<Float>(0.4, 2.5, 1.6, 0),
                                    dir: SIMD4<Float>(0, 1, 0, 0)))
            f.sprites.append(Sprite(posSize: SIMD4<Float>(p.pos.x, p.pos.y, 0, 1.0 * pulse),
                                    color: SIMD4<Float>(0.3, 1.6, 1.0, 1),
                                    dir: SIMD4<Float>(0, 1, 0, 0)))
        }

        // onde d'urto
        for w in shockwaves {
            let k = w.t / w.duration
            let ease = 1 - (1 - k) * (1 - k) * (1 - k)
            let fade = (1 - k) * (1 - k)
            f.sprites.append(Sprite(posSize: SIMD4<Float>(w.pos.x, w.pos.y, 0.1, w.size * ease),
                                    color: SIMD4<Float>(w.color.x * fade, w.color.y * fade, w.color.z * fade, 1),
                                    dir: SIMD4<Float>(0, 1, 0, 0)))
            f.sprites.append(Sprite(posSize: SIMD4<Float>(w.pos.x, w.pos.y, 0.1, w.size * 0.7 * (1 - k)),
                                    color: SIMD4<Float>(3.0 * fade, 2.6 * fade, 2.2 * fade, 0),
                                    dir: SIMD4<Float>(0, 1, 0, 0)))
        }
    }
}
