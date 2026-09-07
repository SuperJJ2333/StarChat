import Flutter
import UIKit

class SceneDelegate: FlutterSceneDelegate {
  override func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
    guard let windowScene = scene as? UIWindowScene,
          let app = UIApplication.shared.delegate as? AppDelegate else { return }
    let engine = app.startSharedEngine()
    let window = UIWindow(windowScene: windowScene)
    // Reattach the same engine that may have been running for a PushKit launch.
    let controller = engine.viewController ?? FlutterViewController(engine: engine, nibName: nil, bundle: nil)
    window.rootViewController = controller
    self.window = window
    registerSceneLifeCycle(with: engine)
    super.scene(scene, willConnectTo: session, options: connectionOptions)
    window.makeKeyAndVisible()
  }
}
