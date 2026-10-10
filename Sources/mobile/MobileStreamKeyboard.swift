#if os(iOS)
import SwiftUI
import SwiftlightCore
import SwiftlightTransport
import UIKit

/// Opaque fills keep shortcuts readable over bright or busy streamed video.
private struct MobileKeyboardButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.body.weight(.semibold))
            .foregroundStyle((configuration.role == .destructive ? Color.red : .white)
                .opacity(isEnabled ? 1 : 0.6))
            .padding(.horizontal, 20).padding(.vertical, 12)
            .frame(minHeight: 52)
            .background(Color(white: configuration.isPressed ? 0.12 : 0.08), in: Capsule())
    }
}

private struct MobileKeyboardAccessory: View {
    let send: (HostKeyboardShortcut) -> Void
    let dismiss: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            ScrollView(.horizontal) {
                HStack(spacing: 12) {
                    Button("Windows") { send(.windows) }
                        .accessibilityIdentifier("streamWindowsKey")
                        .accessibilityHint("Send the Windows key to your computer")
                    Button("Alt–Tab") { send(.altTab) }
                        .accessibilityIdentifier("streamAltTab")
                        .accessibilityHint("Switch windows on your computer")
                    Button("Alt–F4", role: .destructive) { send(.altF4) }
                        .accessibilityIdentifier("streamAltF4")
                        .accessibilityHint("Close the active window on your computer")
                }
            }
            .scrollIndicators(.hidden)
            Button("Hide", systemImage: "keyboard.chevron.compact.down", action: dismiss)
                .labelStyle(.iconOnly)
                .accessibilityLabel("Hide keyboard")
                .accessibilityIdentifier("hideStreamKeyboard")
        }
        .buttonStyle(MobileKeyboardButtonStyle())
        .padding(.horizontal, 8).padding(.vertical, 4)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// The input accessory is attached to the system keyboard, outside the Metal
/// surface. Its SwiftUI content and hosting controller exist only while shown.
@MainActor private final class MobileKeyboardAccessoryView: UIInputView {
    let hostedView: UIView
    private let measureHeight: (CGFloat) -> CGFloat
    init(hostedView: UIView, width: CGFloat, measureHeight: @escaping (CGFloat) -> CGFloat) {
        self.hostedView = hostedView
        self.measureHeight = measureHeight
        super.init(frame: CGRect(x: 0, y: 0, width: width, height: 56), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        hostedView.backgroundColor = .clear
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hostedView)
        NSLayoutConstraint.activate([
            hostedView.leadingAnchor.constraint(equalTo: leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: trailingAnchor),
            hostedView.topAnchor.constraint(equalTo: topAnchor),
            hostedView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (view: MobileKeyboardAccessoryView, _: UITraitCollection) in
            view.invalidateIntrinsicContentSize(); view.setNeedsLayout()
        }
    }
    required init?(coder: NSCoder) { fatalError("Use the hosted-view initializer") }
    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: fittedSize(width: bounds.width).height)
    }
    override func systemLayoutSizeFitting(_ targetSize: CGSize) -> CGSize {
        fittedSize(width: targetSize.width)
    }
    override func systemLayoutSizeFitting(_ targetSize: CGSize,
                                        withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
                                        verticalFittingPriority: UILayoutPriority) -> CGSize {
        fittedSize(width: targetSize.width)
    }
    override func didMoveToSuperview() {
        super.didMoveToSuperview(); fitKeyboardContainer()
    }
    override func layoutSubviews() {
        fitKeyboardContainer(); super.layoutSubviews()
    }
    private func fittedSize(width proposedWidth: CGFloat) -> CGSize {
        let width = proposedWidth.isFinite && proposedWidth > 0 ? proposedWidth : bounds.width
        let measured = measureHeight(width)
        return CGSize(width: width, height: measured.isFinite ? max(56, measured) : 56)
    }
    private func fitKeyboardContainer() {
        guard let superview, superview.bounds.width.isFinite, superview.bounds.width > 0 else { return }
        let size = fittedSize(width: superview.bounds.width)
        if abs(bounds.width - size.width) > 0.5 || abs(bounds.height - size.height) > 0.5 {
            frame.size = size
        }
        // Enable resizing only after UIKit has attached a sized container. An
        // initial width plus its initial 0-to-width change otherwise doubles it.
        autoresizingMask = [.flexibleWidth]
    }
}

@MainActor private final class MobileKeyboardField: UITextField {
    var committed: (() -> Void)?
    var keyboardAccessory: UIInputViewController?
    override var inputAccessoryViewController: UIInputViewController? { keyboardAccessory }
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration { .none }
    override var undoManager: UndoManager? { nil }
    override func unmarkText() { super.unmarkText(); committed?() }
}

/// UIKit owns the accessory controller's placement in its keyboard hierarchy.
/// The SwiftUI host belongs here, rather than to the streaming controller.
@MainActor private final class MobileKeyboardAccessoryController: UIInputViewController {
    private let host: UIHostingController<MobileKeyboardAccessory>
    private let initialWidth: CGFloat
    init(content: MobileKeyboardAccessory, width: CGFloat) {
        initialWidth = width
        host = UIHostingController(rootView: content)
        host.sizingOptions = [.intrinsicContentSize]
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("Use the content initializer") }
    override func loadView() {
        addChild(host)
        inputView = MobileKeyboardAccessoryView(hostedView: host.view, width: initialWidth) { [weak host] width in
            host?.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height ?? 56
        }
        host.didMove(toParent: self)
    }
}

/// Temporary UITextInput owner: UIKit handles language composition; only
/// committed text enters transport. No text or asynchronous key work is retained
/// after hide, input suspension or session retirement.
@MainActor final class MobileStreamKeyboard: NSObject, UITextFieldDelegate {
    private let transport: StreamTransport
    private let canSend: () -> Bool
    private let visibilityChanged: (Bool) -> Void
    private let failed: (Int32) -> Void
    private var field: MobileKeyboardField?
    private static let sentinel = "\u{200B}"
    var isShowing: Bool { field?.isFirstResponder == true }

    init(transport: StreamTransport, canSend: @escaping () -> Bool,
         visibilityChanged: @escaping (Bool) -> Void, failed: @escaping (Int32) -> Void) {
        self.transport = transport; self.canSend = canSend
        self.visibilityChanged = visibilityChanged; self.failed = failed
    }
    @discardableResult func show(in view: UIView) -> Bool {
        guard canSend(), view.window != nil else { hide(); return false }
        if isShowing { return true }
        hide()
        let field = MobileKeyboardField(frame: .zero)
        field.autocorrectionType = .no; field.spellCheckingType = .no
        field.autocapitalizationType = .none
        field.smartQuotesType = .no; field.smartDashesType = .no; field.smartInsertDeleteType = .no
        field.keyboardType = .default; field.returnKeyType = .default
        field.enablesReturnKeyAutomatically = false
        field.textColor = .clear; field.tintColor = .clear
        field.isAccessibilityElement = false; field.accessibilityElementsHidden = true
        field.inputAssistantItem.leadingBarButtonGroups = []; field.inputAssistantItem.trailingBarButtonGroups = []
        field.delegate = self
        field.addTarget(self, action: #selector(editingChanged(_:)), for: .editingChanged)
        field.committed = { [weak self, weak field] in
            guard let field else { return }
            self?.editingChanged(field)
        }
        let accessory = MobileKeyboardAccessoryController(content: MobileKeyboardAccessory(
            send: { [weak self, weak field] shortcut in
                guard let self, let field, self.field === field else { return }
                self.send(shortcut)
            }, dismiss: { [weak self, weak field] in
                guard let self, let field, self.field === field else { return }
                self.hide()
            }), width: view.bounds.width)
        field.keyboardAccessory = accessory
        self.field = field
        reset(field)
        view.addSubview(field)
        guard field.becomeFirstResponder() else { hide(); return false }
        visibilityChanged(true)
        return true
    }
    func hide() {
        guard let field else { return }
        // Retire the owner first; UIKit callbacks during resignation are stale.
        self.field = nil
        field.delegate = nil; field.committed = nil
        field.removeTarget(self, action: #selector(editingChanged(_:)), for: .editingChanged)
        field.resignFirstResponder(); field.text = nil; field.keyboardAccessory = nil
        field.removeFromSuperview()
        transport.releaseAllInputs()
        visibilityChanged(false)
    }
    private func reset(_ field: UITextField) {
        field.text = Self.sentinel
        let end = field.endOfDocument
        field.selectedTextRange = field.textRange(from: end, to: end)
    }
    @objc private func editingChanged(_ field: UITextField) {
        guard field === self.field, isShowing else { return }
        guard canSend() else { hide(); return }
        guard field.markedTextRange == nil else { return }
        let value = field.text ?? ""
        if value.isEmpty { perform { transport.keyStroke(0x08) } }
        else {
            let text = value.hasPrefix(Self.sentinel) ? String(value.dropFirst()) : value
            guard let actions = SoftKeyboardTextInput.actions(for: text) else { inputFailed(-4); return }
            for action in actions {
                guard self.field === field, canSend() else { break }
                switch action {
                case let .key(key, modifiers): perform { transport.keyStroke(key, modifiers: modifiers) }
                case let .text(text): perform { transport.sendText(text) }
                }
            }
        }
        if field === self.field { reset(field) }
    }
    func textField(_ field: UITextField, shouldChangeCharactersIn range: NSRange,
                   replacementString string: String) -> Bool {
        guard field === self.field else { return false }
        guard canSend() else { hide(); return false }
        // Bound UIKit's local composing buffer too, before accepting large paste
        // or dictation edits. The planner validates a committed UTF-8 payload.
        let current = field.text ?? ""
        guard string.utf8.count <= 4096, let replacementRange = Range(range, in: current) else {
            inputFailed(-4); return false
        }
        let proposed = current.replacingCharacters(in: replacementRange, with: string)
        let committed = proposed.hasPrefix(Self.sentinel) ? String(proposed.dropFirst()) : proposed
        guard committed.utf8.count <= 4096 else {
            inputFailed(-4); return false
        }
        return true
    }
    func textFieldShouldReturn(_ field: UITextField) -> Bool {
        guard field === self.field, isShowing else { return false }
        guard canSend() else { hide(); return false }
        guard field.markedTextRange == nil else { return false }
        perform { transport.keyStroke(0x0D) }
        return false
    }
    func textFieldDidEndEditing(_ field: UITextField) {
        if field === self.field { hide() }
    }
    private func send(_ shortcut: HostKeyboardShortcut) {
        guard isShowing else { return }
        guard canSend() else { hide(); return }
        perform { transport.keyChord(shortcut) }
    }
    private func perform(_ action: () -> Int32) {
        let result = action()
        if result != 0 { inputFailed(result) }
    }
    private func inputFailed(_ result: Int32) {
        hide(); failed(result)
    }
}
#endif
