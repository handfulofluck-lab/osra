import Flutter
import GoogleMaps
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // #598: the Google Maps SDK aborts in `checkServicePreconditions` when no key was provided, which is
    // what crashed the Family map on iOS. The key reaches the bundle through `Info.plist`'s `MAPS_API_KEY`,
    // which the build sets from the same `--dart-define` secret CI passes to Flutter — never committed.
    // Without it the app still launches and the map screen renders its "not available" state, because a
    // missing key must cost a map, not the whole app.
    if let mapsKey = Bundle.main.object(forInfoDictionaryKey: "MAPS_API_KEY") as? String,
       !mapsKey.isEmpty, mapsKey != "$(MAPS_API_KEY)" {
      GMSServices.provideAPIKey(mapsKey)
    }
    // #558: plugins register later, in `didInitializeImplicitFlutterEngine`, so firebase_messaging
    // misses its own launch hook and iOS was never asked for a device token. Without one FCM cannot
    // mint a token and the parent never received a push. FlutterAppDelegate forwards the
    // `didRegisterForRemoteNotificationsWithDeviceToken` callback to the plugin, which hands it to FCM.
    application.registerForRemoteNotifications()
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
