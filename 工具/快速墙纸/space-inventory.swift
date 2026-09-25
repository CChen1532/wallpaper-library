// Read-only identity adapter. Never switches Spaces or changes window tags.
import AppKit
import Darwin
import Foundation
func fail(_ message: String) -> Never { fputs(message + "\n", stderr); exit(2) }
let args = CommandLine.arguments
let requested = args.count > 1 ? UInt32(args[1]) : nil
let screens = NSScreen.screens
let screen = requested.flatMap { id in screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id } } ?? (requested == nil ? NSScreen.main : nil)
guard let screen,
      let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value,
      let displayUUID = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue(),
      let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY),
      let mainSymbol = dlsym(library, "SLSMainConnectionID"),
      let copySymbol = dlsym(library, "SLSCopyManagedDisplaySpaces") else { fail("无法读取显示器和 Space 标识；未更改设置") }
typealias Main = @convention(c) () -> Int32
typealias Copy = @convention(c) (Int32) -> Unmanaged<CFArray>?
let main = unsafeBitCast(mainSymbol, to: Main.self)
let copy = unsafeBitCast(copySymbol, to: Copy.self)
let uuid = CFUUIDCreateString(nil, displayUUID) as String
let displays = copy(main())?.takeRetainedValue() as? [[String: Any]] ?? []
guard let managed = displays.first(where: { ($0["Display Identifier"] as? String) == uuid }),
      let spaces = managed["Spaces"] as? [[String: Any]] else { fail("无法对应显示器的 Space 列表；未更改设置") }
var rows: [[String: Any]] = []
for item in spaces where (item["type"] as? Int) == 0 {
    guard let spaceUUID = item["uuid"] as? String, !spaceUUID.isEmpty,
          let managedID = item["ManagedSpaceID"] as? Int else { fail("Space 数据格式不受支持") }
    rows.append(["number": rows.count + 1, "uuid": spaceUUID, "id": managedID])
}
let object: [String: Any] = ["display_id": id, "display_uuid": uuid, "spaces": rows]
let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
print(String(decoding: data, as: UTF8.self))
