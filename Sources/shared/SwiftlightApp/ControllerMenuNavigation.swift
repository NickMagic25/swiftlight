import SwiftUI
import SwiftlightCore

/// Local library selection is independent of the computer being authenticated.
/// Moving across the sidebar never starts network work until the player activates it.
struct ControllerMenuNavigation: Equatable {
    enum Region { case computers, applications }

    var region = Region.computers
    var computerID: String?
    var applicationID: Int?
    var applicationColumns = 1
    var isActive = false

    mutating func move(_ direction: MenuControllerDirection, computers: [String], applications: [Int]) {
        if region == .computers {
            if direction == .right {
                region = .applications
                applicationID = applications.contains(applicationID ?? -1) ? applicationID : applications.first
            } else if direction == .up || direction == .down {
                computerID = Self.nextIndex(current: computerID.flatMap { computers.firstIndex(of: $0) },
                                            count: computers.count, columns: 1, direction: direction).map { computers[$0] }
            }
        } else {
            let current = applicationID.flatMap { applications.firstIndex(of: $0) }
            if direction == .left, current.map({ $0 % max(1, applicationColumns) == 0 }) ?? true {
                returnToComputers(computers)
            } else {
                applicationID = Self.nextIndex(current: current, count: applications.count,
                                               columns: applicationColumns, direction: direction).map { applications[$0] }
            }
        }
    }

    mutating func returnToComputers(_ computers: [String]) {
        region = .computers
        if !computers.contains(computerID ?? "") { computerID = computers.first }
    }

    mutating func selectedComputer(_ id: String) {
        computerID = id
        applicationID = nil
        region = .applications
    }

    /// Stay within a visual row horizontally; clamp a shorter last row vertically.
    static func nextIndex(current: Int?, count: Int, columns: Int, direction: MenuControllerDirection) -> Int? {
        guard count > 0 else { return nil }
        guard let current, (0..<count).contains(current) else { return 0 }
        let columns = max(1, columns)
        switch direction {
        case .up: return current >= columns ? current - columns : current
        case .down: return current / columns < (count - 1) / columns ? min(current + columns, count - 1) : current
        case .left: return current % columns > 0 ? current - 1 : current
        case .right: return current % columns < columns - 1 && current + 1 < count ? current + 1 : current
        }
    }

    static func columnCount(width: CGFloat, minimum: CGFloat, spacing: CGFloat) -> Int {
        guard width.isFinite, width > 0, minimum > 0, spacing >= 0 else { return 1 }
        return max(1, Int((width + spacing) / (minimum + spacing)))
    }
}

private struct ControllerMenuInputModifier: ViewModifier {
    let enabled: Bool
    let handler: @MainActor (MenuControllerAction) -> Void
    @State private var owner = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { updateRouting() }
            .onChange(of: enabled) { _, _ in updateRouting() }
            .onDisappear { ControllerHub.shared.clearMenuHandler(owner: owner) }
    }

    private func updateRouting() {
        if enabled { ControllerHub.shared.setMenuHandler(owner: owner, handler: handler) }
        else { ControllerHub.shared.clearMenuHandler(owner: owner) }
    }
}

extension View {
    func controllerMenuInput(enabled: Bool, handler: @escaping @MainActor (MenuControllerAction) -> Void) -> some View {
        modifier(ControllerMenuInputModifier(enabled: enabled, handler: handler))
    }

    func controllerMenuHighlight(_ selected: Bool) -> some View {
        overlay {
            if selected {
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color.accentColor, lineWidth: 3)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}
