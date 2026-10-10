#if os(iOS)
import GameController
import SwiftUI
import UIKit

/// Keep controller events in GameController profiles while SwiftUI owns menus.
/// The event controller is only an input adapter; touch, keyboard and accessibility
/// continue through the ordinary hosting controller and system controls.
struct MobileControllerEventContent<Content: View>: UIViewControllerRepresentable {
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    func makeUIViewController(context: Context) -> Controller {
        Controller(content: content)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.host.rootView = content
    }

    final class Controller: GCEventViewController {
        let host: UIHostingController<Content>

        init(content: Content) {
            host = UIHostingController(rootView: content)
            super.init(nibName: nil, bundle: nil)
            controllerUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidLoad() {
            super.viewDidLoad()
            addChild(host)
            host.view.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(host.view)
            NSLayoutConstraint.activate([
                host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                host.view.topAnchor.constraint(equalTo: view.topAnchor),
                host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
            ])
            host.didMove(toParent: self)
        }
    }
}
#endif
