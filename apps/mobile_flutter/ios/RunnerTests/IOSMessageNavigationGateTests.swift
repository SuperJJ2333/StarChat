import XCTest
import UIKit
@testable import Runner

final class IOSMessageNavigationGateTests: XCTestCase {
  func testBackgroundOrInactiveApplicationCannotNavigateToMessages() {
    for state in [UIApplication.State.background, .inactive] {
      XCTAssertFalse(IOSMessageNavigationGate.allows(
        applicationState: state, sceneStates: [.foregroundActive]))
    }
  }

  func testActiveApplicationStillRequiresAnActiveScene() {
    for states in [[UIScene.ActivationState](), [.background], [.foregroundInactive], [.unattached]] {
      XCTAssertFalse(IOSMessageNavigationGate.allows(
        applicationState: .active, sceneStates: states))
    }
    XCTAssertTrue(IOSMessageNavigationGate.allows(
      applicationState: .active, sceneStates: [.background, .foregroundActive]))
  }
}
