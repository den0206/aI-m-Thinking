import Foundation

struct MoodActivity: Equatable {
    let agent: AgentService
    let phase: String
    let intensity: Double
    var isActive: Bool {
        ["thinking", "writing", "tool"].contains(phase) && intensity.isFinite && intensity >= 0.06
    }
}

struct MoodAppearance: Equatable {
    let agent: AgentService
    let level: Int
    static let levels = 32
}

struct MoodSelection {
    private(set) var selected: MoodActivity?
    private(set) var deadline: TimeInterval?
    private var selectedAt: TimeInterval = 0
    private var contender: AgentService?
    private var contenderSince: TimeInterval = 0

    mutating func update(_ activities: [MoodActivity], now: TimeInterval) {
        let active = AgentService.allCases.compactMap { agent in
            activities.filter {
                $0.agent == agent && $0.isActive
            }.sorted {
                $0.intensity == $1.intensity ? $0.phase < $1.phase : $0.intensity > $1.intensity
            }.first
        }
        let strongest = active.max { $0.intensity < $1.intensity }
        guard let current = active.first(where: { $0.agent == selected?.agent }) else {
            selected = strongest
            selectedAt = now
            contender = nil
            deadline = nil
            return
        }
        selected = current
        guard let challenger = strongest, challenger.agent != current.agent,
              challenger.intensity >= current.intensity + 0.15 else {
            contender = nil
            deadline = nil
            return
        }
        if contender != challenger.agent {
            contender = challenger.agent
            contenderSince = now
        }
        let due = max(contenderSince + 0.8, selectedAt + 2)
        if now >= due {
            selected = challenger
            selectedAt = now
            contender = nil
            deadline = nil
        } else {
            deadline = due
        }
    }
}

@MainActor
final class MoodCoordinator: ObservableObject {
    @Published private(set) var appearance: MoodAppearance?
    private(set) var selection = MoodSelection()
    private var activities: [MoodActivity] = []
    private var glow = 0.3
    private var reducedMotion = false
    private var phaseStarted: TimeInterval = 0
    private var lastRender: TimeInterval = -.infinity
    private var transition: (from: MoodAppearance?, start: TimeInterval)?
    private var deadlineTask: Task<Void, Never>?
    private var animationTask: Task<Void, Never>?
    var isAnimating: Bool { animationTask != nil }
    var hasPendingSelection: Bool { deadlineTask != nil }

    deinit {
        deadlineTask?.cancel()
        animationTask?.cancel()
    }

    func update(_ activities: [MoodActivity], enabled: Bool, glow: Double, reducedMotion: Bool) {
        guard enabled else { reset(); return }
        let glow = glow.isFinite ? max(0, min(1, glow)) : 0.3
        let changed = self.glow != glow || self.reducedMotion != reducedMotion
        self.activities = activities
        self.glow = glow
        self.reducedMotion = reducedMotion
        evaluate(forceRender: changed)
    }

    func reset() {
        deadlineTask?.cancel()
        deadlineTask = nil
        animationTask?.cancel()
        animationTask = nil
        activities = []
        selection = MoodSelection()
        transition = nil
        appearance = nil
        lastRender = -.infinity
    }

    private func evaluate(forceRender: Bool = false) {
        let now = ProcessInfo.processInfo.systemUptime
        let previous = selection.selected
        let previousDeadline = selection.deadline
        selection.update(activities, now: now)
        guard let selected = selection.selected else { reset(); return }
        if selected.agent != previous?.agent {
            let outgoing = appearance.flatMap { image in
                activities.contains(where: { $0.agent == image.agent && $0.isActive }) ? image : nil
            }
            transition = (outgoing, now)
        }
        if selected.agent != previous?.agent || selected.phase != previous?.phase {
            phaseStarted = now
        }
        if reducedMotion { transition = nil }
        if selection.deadline != previousDeadline || deadlineTask == nil {
            deadlineTask?.cancel()
            deadlineTask = nil
            if let deadline = selection.deadline {
                deadlineTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(max(0, deadline - ProcessInfo.processInfo.systemUptime)))
                    guard !Task.isCancelled else { return }
                    self?.deadlineTask = nil
                    self?.evaluate()
                }
            }
        }
        render(now: now, force: forceRender || selected.agent != previous?.agent || selected.phase != previous?.phase)
        if !needsAnimation(now: now) {
            animationTask?.cancel()
            animationTask = nil
        } else if animationTask == nil {
            animationTask = Task { [weak self] in
                while !Task.isCancelled {
                    let milliseconds = self?.transition == nil ? 100 : 50
                    try? await Task.sleep(for: .milliseconds(milliseconds))
                    guard !Task.isCancelled, let self else { return }
                    let now = ProcessInfo.processInfo.systemUptime
                    self.render(now: now)
                    if !self.needsAnimation(now: now) {
                        self.animationTask = nil
                        return
                    }
                }
            }
        }
    }

    private func needsAnimation(now: TimeInterval) -> Bool {
        guard !reducedMotion, glow > 0, let selected = selection.selected else { return false }
        return transition != nil || selected.phase == "thinking"
            || (selected.phase == "tool" && now - phaseStarted < 0.4)
    }

    private func render(now: TimeInterval, force: Bool = false) {
        guard let selected = selection.selected,
              force || now - lastRender >= (transition == nil ? 0.1 : 0.05) else { return }
        lastRender = now
        if glow == 0 {
            transition = nil
            appearance = nil
            return
        }
        var brightness = glow * (0.45 + 0.55 * min(1, selected.intensity))
        switch selected.phase {
        case "thinking":
            brightness *= reducedMotion ? 0.75 : 0.75 * (0.86 + 0.14 * cos((now - phaseStarted) * 2 * .pi / 3))
        case "tool":
            brightness *= 0.8 + (reducedMotion ? 0 : 0.2 * max(0, 1 - (now - phaseStarted) / 0.4))
        default: break
        }
        var agent = selected.agent
        if let transition {
            let progress = min(1, max(0, (now - transition.start) / 0.3))
            if progress >= 1 {
                self.transition = nil
            } else if let from = transition.from, from.agent != selected.agent, progress < 0.5 {
                agent = from.agent
                brightness = Double(from.level) / Double(MoodAppearance.levels) * (1 - progress * 2)
            } else {
                // Fade through neutral instead of mixing two Agent colors.
                brightness *= transition.from == nil ? progress : max(0, progress * 2 - 1)
            }
        }
        let level = Int((brightness * Double(MoodAppearance.levels)).rounded())
        let next = level > 0 ? MoodAppearance(agent: agent, level: level) : nil
        if next != appearance { appearance = next }
    }
}
