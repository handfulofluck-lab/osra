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
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
