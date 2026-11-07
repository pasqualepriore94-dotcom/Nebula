import UIKit
import MetalKit

final class GameViewController: UIViewController {
    private var mtkView: MTKView?
    private var renderer: Renderer?
    private let game = Game()

    private let scoreLabel = UILabel()
    private let infoLabel = UILabel()
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    private let lightHaptic = UIImpactFeedbackGenerator(style: .rigid)
    private let heavyHaptic = UIImpactFeedbackGenerator(style: .heavy)
    private let notifyHaptic = UINotificationFeedbackGenerator()

    private var lastTouch: CGPoint?
    private let touchSensitivity: Float = 0.032

    override func loadView() {
        guard let device = MTLCreateSystemDefaultDevice() else {
            let v = UIView()
            v.backgroundColor = .black
            view = v
            return
        }
        let v = MTKView(frame: .zero, device: device)
        v.colorPixelFormat = .bgra8Unorm
        v.depthStencilPixelFormat = .invalid
        v.framebufferOnly = false
        v.preferredFramesPerSecond = 120
        v.isMultipleTouchEnabled = false
        v.backgroundColor = .black
        mtkView = v
        view = v
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        setupHUD()

        guard let mtkView = mtkView else {
            showError("Metal non disponibile su questo dispositivo.")
            return
        }
        do {
            let r = try Renderer(view: mtkView, game: game)
            renderer = r
            mtkView.delegate = r
        } catch {
            showError("Errore grafico: \(error)")
            return
        }

        game.onHUD = { [weak self] in self?.refreshHUD() }
        game.onHaptic = { [weak self] e in self?.haptic(e) }
        lightHaptic.prepare()
        heavyHaptic.prepare()
        refreshHUD()
    }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }

    // MARK: - HUD

    private func setupHUD() {
        let glow: (UILabel, UIColor) -> Void = { label, color in
            label.layer.shadowColor = color.cgColor
            label.layer.shadowRadius = 10
            label.layer.shadowOpacity = 0.9
            label.layer.shadowOffset = .zero
            label.translatesAutoresizingMaskIntoConstraints = false
            label.isUserInteractionEnabled = false
        }
        let cyan = UIColor(red: 0.4, green: 0.9, blue: 1.0, alpha: 1)

        scoreLabel.font = .monospacedDigitSystemFont(ofSize: 26, weight: .heavy)
        scoreLabel.textColor = .white
        glow(scoreLabel, cyan)

        infoLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        infoLabel.textColor = UIColor(white: 1, alpha: 0.85)
        infoLabel.textAlignment = .right
        infoLabel.numberOfLines = 2
        glow(infoLabel, cyan)

        titleLabel.textAlignment = .center
        glow(titleLabel, cyan)
        titleLabel.layer.shadowRadius = 22

        subtitleLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        subtitleLabel.textColor = UIColor(white: 1, alpha: 0.9)
        subtitleLabel.textAlignment = .center
        subtitleLabel.numberOfLines = 0
        glow(subtitleLabel, cyan)

        for l in [scoreLabel, infoLabel, titleLabel, subtitleLabel] { view.addSubview(l) }
        let g = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            scoreLabel.leadingAnchor.constraint(equalTo: g.leadingAnchor, constant: 20),
            scoreLabel.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
            infoLabel.trailingAnchor.constraint(equalTo: g.trailingAnchor, constant: -20),
            infoLabel.topAnchor.constraint(equalTo: g.topAnchor, constant: 8),
            titleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            titleLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -80),
            subtitleLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 18),
            subtitleLabel.leadingAnchor.constraint(greaterThanOrEqualTo: g.leadingAnchor, constant: 24),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: g.trailingAnchor, constant: -24)
        ])
    }

    private func setTitle(_ text: String, size: CGFloat) {
        titleLabel.attributedText = NSAttributedString(string: text, attributes: [
            .font: UIFont.systemFont(ofSize: size, weight: .black),
            .foregroundColor: UIColor.white,
            .kern: size * 0.18
        ])
    }

    private func refreshHUD() {
        scoreLabel.text = String(format: "%07d", game.score)
        let hearts = String(repeating: "◆ ", count: max(0, game.lives))
        infoLabel.text = "\(hearts)\nRECORD \(game.best)"

        switch game.state {
        case .title:
            setTitle("NEBULA", size: 58)
            subtitleLabel.text = "Trascina il dito per pilotare\nTocca per iniziare"
            titleLabel.isHidden = false
            subtitleLabel.isHidden = false
            scoreLabel.isHidden = true
            infoLabel.text = "RECORD \(game.best)"
        case .playing:
            titleLabel.isHidden = true
            subtitleLabel.isHidden = true
            scoreLabel.isHidden = false
        case .gameOver:
            setTitle("GAME OVER", size: 44)
            let record = game.score >= game.best && game.score > 0 ? "\nNuovo record!" : ""
            subtitleLabel.text = "Punteggio \(game.score)\(record)\n\nTocca per riprovare"
            titleLabel.isHidden = false
            subtitleLabel.isHidden = false
            scoreLabel.isHidden = false
        }
    }

    private func showError(_ text: String) {
        setTitle("NEBULA", size: 40)
        subtitleLabel.text = text
    }

    private func haptic(_ e: HapticEvent) {
        switch e {
        case .kill: lightHaptic.impactOccurred(intensity: 0.7)
        case .hurt: heavyHaptic.impactOccurred()
        case .pickup: notifyHaptic.notificationOccurred(.success)
        case .gameOver: notifyHaptic.notificationOccurred(.error)
        }
    }

    // MARK: - Tocco

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first else { return }
        lastTouch = t.location(in: view)
        game.tap()
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let t = touches.first, let last = lastTouch else { return }
        let p = t.location(in: view)
        let d = SIMD2<Float>(Float(p.x - last.x), Float(last.y - p.y)) * touchSensitivity
        game.drag(by: d)
        lastTouch = p
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) { lastTouch = nil }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) { lastTouch = nil }
}
