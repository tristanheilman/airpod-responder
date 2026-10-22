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
var received = 0
var windowStart = Date()
manager.startDeviceMotionUpdates(to: .main) { motion, error in
    if let error { print("error:", error); return }
    guard let m = motion else { return }
    received += 1
    let now = Date()
    if now.timeIntervalSince(windowStart) >= 1 {
        print("rate: \(received) samples/s")
        received = 0; windowStart = now
    }
    guard now.timeIntervalSince(lastPrint) >= 0.2 else { return }
    lastPrint = now
    let a = m.attitude, r = m.rotationRate
    print(String(format: "pitch %+.2f yaw %+.2f roll %+.2f | rate x %+.2f y %+.2f z %+.2f",
                 a.pitch, a.yaw, a.roll, r.x, r.y, r.z))
}
// Optional first argument: seconds to run, then exit — so it can be run
// non-interactively (from `! ...` in a session, or from launchd) and still end.
if let seconds = CommandLine.arguments.dropFirst().first.flatMap(Double.init) {
    print("running for \(Int(seconds))s — nod a few times, shake a few times, then sit still")
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
        print("done; stopping updates")
        exit(0)
    }
    RunLoop.main.run()
} else {
    print("waiting for updates — Ctrl-C to stop")
    RunLoop.main.run()
}
