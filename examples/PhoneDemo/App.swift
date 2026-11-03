import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = DemoController()
        window.makeKeyAndVisible(); self.window = window
        return true
    }
}

final class DemoController: UIViewController, UIScrollViewDelegate {
    private var count = 0
    private let counter = UILabel()
    private let entry = UITextField()
    private let echoed = UILabel()
    private let page = UILabel()
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = UILabel(); title.text = "terminal-phone"; title.font = .systemFont(ofSize: 30, weight: .bold)
        let subtitle = UILabel(); subtitle.text = "A small app for agent UI testing"; subtitle.textColor = .secondaryLabel
        counter.text = "Count: 0"; counter.accessibilityIdentifier = "counter"; counter.font = .systemFont(ofSize: 24, weight: .semibold)
        let increment = UIButton(type: .system)
        increment.setTitle("Increment", for: .normal); increment.accessibilityIdentifier = "increment"
        increment.addTarget(self, action: #selector(incrementCount), for: .touchUpInside)
        entry.borderStyle = .roundedRect; entry.placeholder = "Type a message"; entry.accessibilityIdentifier = "message"
        // Keep this automation fixture deterministic instead of applying iOS text substitutions.
        entry.autocapitalizationType = .none; entry.autocorrectionType = .no
        entry.smartDashesType = .no; entry.smartQuotesType = .no; entry.spellCheckingType = .no
        let submit = UIButton(type: .system); submit.setTitle("Show message", for: .normal); submit.accessibilityIdentifier = "submit"
        submit.addTarget(self, action: #selector(showMessage), for: .touchUpInside)
        echoed.text = "Message: empty"; echoed.accessibilityIdentifier = "echo"; echoed.numberOfLines = 0
        let scroller = UIScrollView(); scroller.isPagingEnabled = true; scroller.bounces = false
        scroller.showsHorizontalScrollIndicator = false; scroller.delegate = self
        scroller.accessibilityIdentifier = "swipe-pages"
        let pages = UIStackView(); pages.axis = .horizontal; pages.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(pages)
        for text in ["Drag left →", "← Drag right"] {
            let label = UILabel(); label.text = text; label.textAlignment = .center
            label.backgroundColor = .secondarySystemBackground; pages.addArrangedSubview(label)
            label.widthAnchor.constraint(equalTo: scroller.frameLayoutGuide.widthAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            pages.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            pages.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            pages.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            pages.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            pages.heightAnchor.constraint(equalTo: scroller.frameLayoutGuide.heightAnchor),
            scroller.heightAnchor.constraint(equalToConstant: 100)
        ])
        page.text = "Page: 1"; page.accessibilityIdentifier = "page"
        let stack = UIStackView(arrangedSubviews: [title, subtitle, counter, increment, entry, submit, echoed, scroller, page])
        stack.axis = .vertical; stack.spacing = 20; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 40),
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            entry.heightAnchor.constraint(equalToConstant: 44)
        ])
    }
    @objc private func incrementCount() { count += 1; counter.text = "Count: \(count)" }
    @objc private func showMessage() { echoed.text = "Message: \(entry.text ?? "")"; entry.resignFirstResponder() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        page.text = "Page: \(Int((scrollView.contentOffset.x / max(1, scrollView.bounds.width)).rounded()) + 1)"
    }
}
