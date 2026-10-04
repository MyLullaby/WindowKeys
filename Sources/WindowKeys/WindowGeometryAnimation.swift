import AppKit

final class WindowGeometryAnimation: NSAnimation {
    private let applyFrame: (CGFloat) -> Bool
    private let completion: () -> Void
    private var cleanup: (() -> Void)?
    private var finished = false

    init(applyFrame: @escaping (CGFloat) -> Bool, completion: @escaping () -> Void,
         cleanup: @escaping () -> Void) {
        self.applyFrame = applyFrame
        self.completion = completion
        self.cleanup = cleanup
        super.init(duration: 0.3, animationCurve: .easeOut)
        animationBlockingMode = .nonblocking
        frameRate = Float(NSScreen.main?.maximumFramesPerSecond ?? 60)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit { cleanup?() }

    private func restoreState() {
        let action = cleanup
        cleanup = nil
        action?()
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        super.stop()
        restoreState()
    }

    override var currentProgress: NSAnimation.Progress {
        didSet {
            guard !finished else { return }
            let eased = 1 - pow(1 - CGFloat(currentValue), 3)
            guard applyFrame(eased) else { cancel(); return }
            if currentProgress >= 1 {
                finished = true
                super.stop()
                defer { restoreState() }
                completion()
            }
        }
    }
}

