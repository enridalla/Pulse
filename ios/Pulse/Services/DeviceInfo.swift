import Foundation
import UIKit

/// Small facade over device / bundle information. Keeps UIKit out of the pure layers.
enum DeviceInfo {
    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }

    static var deviceModel: String {
        UIDevice.current.model
    }

    static var systemVersion: String {
        "iOS \(UIDevice.current.systemVersion)"
    }
}
