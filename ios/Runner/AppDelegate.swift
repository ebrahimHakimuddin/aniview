import Flutter
import UIKit
import AVFAudio

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // media_kit renders the video; iOS owns its audio route and silent-switch policy.
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    } catch {
      NSLog("Could not configure playback audio: %@", error.localizedDescription)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let channel = FlutterMethodChannel(
      name: "aniview/ios", binaryMessenger: engineBridge.applicationRegistrar.messenger())
    channel.setMethodCallHandler { call, result in
      guard call.method == "open" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard let address = call.arguments as? String, let url = URL(string: address),
        ["https", "http"].contains(url.scheme?.lowercased() ?? ""), url.host != nil
      else {
        result(FlutterError(code: "url", message: "Expected a web URL", details: nil))
        return
      }
      UIApplication.shared.open(url, options: [:]) { opened in
        result(opened ? nil : FlutterError(
          code: "open", message: "Could not open the browser", details: nil))
      }
    }
  }
}
