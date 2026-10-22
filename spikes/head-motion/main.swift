// Throwaway: does CMHeadphoneMotionManager deliver anything on this Mac?
// Build and run with ./run.sh, AirPods in. Prints pitch/yaw/roll at ~5Hz.
import CoreMotion
import Foundation

setvbuf(stdout, nil, _IOLBF, 0)  // so `| tee` and `> file` see lines as they happen

final class Delegate: NSObject, CMHeadphoneMotionManagerDelegate {
    func headphoneMotionManagerDidConnect(_ m: CMHeadphoneMotionManager) { print("headphones connected") }
    func headphoneMotionManagerDidDisconnect(_ m: CMHeadphoneMotionManager) { print("headphones disconnected") }
}

let manager = CMHeadphoneMotionManager()
let delegate = Delegate()
manager.delegate = delegate
print("isDeviceMotionAvailable:", manager.isDeviceMotionAvailable)
print("authorizationStatus:", CMHeadphoneMotionManager.authorizationStatus().rawValue,
      "(0 notDetermined, 1 restricted, 2 denied, 3 authorized)")

var lastPrint = Date.distantPast
manager.startDeviceMotionUpdates(to: .main) { motion, error in
    if let error { print("error:", error); return }
    guard let a = motion?.attitude, Date().timeIntervalSince(lastPrint) >= 0.2 else { return }
    lastPrint = Date()
    print(String(format: "pitch %+.3f  yaw %+.3f  roll %+.3f", a.pitch, a.yaw, a.roll))
}
print("waiting for updates — Ctrl-C to stop")
RunLoop.main.run()
