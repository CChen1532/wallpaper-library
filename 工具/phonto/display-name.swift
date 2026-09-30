import AppKit
import CoreGraphics
let names = NSScreen.screens.compactMap { screen -> (String, String)? in
    guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
          let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue() else { return nil }
    return (CFUUIDCreateString(nil, uuid) as String, screen.localizedName)
}
if CommandLine.arguments.count == 2,
   let screen = names.first(where: { $0.0 == CommandLine.arguments[1] }),
   names.filter({ $0.1 == screen.1 }).count == 1 {
    print(screen.1)
} else { exit(1) }
