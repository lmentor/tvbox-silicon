import SwiftUI

/// Remove the navigation bar's reserved row, while retaining UIKit's interactive
/// transition. The helper is scoped to this pushed page and restores its delegate.
struct LocalDetailNavigation: ViewModifier {
    func body(content: Content) -> some View {
        #if os(iOS)
        content.navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar(.hidden, for: .navigationBar)
            .background(LocalDetailBackGesture().frame(width: 0, height: 0).allowsHitTesting(false))
        #else
        content
        #endif
    }
}

#if os(iOS)
import UIKit

private struct LocalDetailBackGesture: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> LocalDetailBackController { LocalDetailBackController() }
    func updateUIViewController(_ controller: LocalDetailBackController, context: Context) { controller.refreshIfVisible() }
    static func dismantleUIViewController(_ controller: LocalDetailBackController, coordinator: ()) { controller.restore() }
}

private final class LocalDetailBackController: UIViewController, UIGestureRecognizerDelegate {
    private weak var navigation: UINavigationController?
    private weak var owner: UIViewController?
    private weak var previousDelegate: (any UIGestureRecognizerDelegate)?
    private var previouslyEnabled = false
    private var visible = false

    override func loadView() { view = UIView(); view.isUserInteractionEnabled = false; view.backgroundColor = .clear }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated); visible = true; refreshIfVisible()
    }
    override func viewWillDisappear(_ animated: Bool) {
        visible = false; restore(); super.viewWillDisappear(animated)
    }
    override func viewDidLayoutSubviews() { super.viewDidLayoutSubviews(); refreshIfVisible() }

    func refreshIfVisible() {
        guard visible, view.window != nil,
              let nav = navigationController, nav.viewControllers.count > 1,
              let gesture = nav.interactivePopGestureRecognizer else { return }
        if gesture.delegate === self { return }
        restore()
        navigation = nav; owner = nav.topViewController
        previousDelegate = gesture.delegate; previouslyEnabled = gesture.isEnabled
        gesture.delegate = self; gesture.isEnabled = true
    }

    func restore() {
        if let gesture = navigation?.interactivePopGestureRecognizer, gesture.delegate === self {
            gesture.delegate = previousDelegate
            gesture.isEnabled = previouslyEnabled
        }
        navigation = nil; owner = nil; previousDelegate = nil
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard visible, let navigation, let owner,
              navigation.topViewController === owner,
              navigation.viewControllers.count > 1,
              navigation.presentedViewController == nil,
              navigation.transitionCoordinator == nil else { return false }
        return true
    }
}
#endif
