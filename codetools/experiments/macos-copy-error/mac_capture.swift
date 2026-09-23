import AppKit
import ApplicationServices
import Foundation

func fail(_ text: String) -> Never { fputs(text + "\n", stderr); exit(1) }
let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else { fail("command required") }
let pb = NSPasteboard.general
switch command {
case "status":
    print("accessibility=\(AXIsProcessTrusted()) screen_capture=\(CGPreflightScreenCaptureAccess())")
case "front":
    print(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)
case "focus":
    guard args.count == 2, let pid = Int32(args[1]), let app = NSRunningApplication(processIdentifier: pid) else { fail("invalid pid") }
    guard AXIsProcessTrusted() else { fail("Accessibility access required") }
    guard app.activate(options: [.activateIgnoringOtherApps]) else { fail("could not activate target") }
case "click":
    guard AXIsProcessTrusted() else { fail("Accessibility access required") }
    guard args.count == 4, let x = Double(args[1]), let y = Double(args[2]) else { fail("click x y left|right") }
    let right = args[3] == "right", point = CGPoint(x: x, y: y)
    CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
    usleep(40000)
    CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseDown : .leftMouseDown, mouseCursorPosition: point, mouseButton: right ? .right : .left)?.post(tap: .cghidEventTap)
    usleep(40000)
    CGEvent(mouseEventSource: nil, mouseType: right ? .rightMouseUp : .leftMouseUp, mouseCursorPosition: point, mouseButton: right ? .right : .left)?.post(tap: .cghidEventTap)
case "key":
    guard AXIsProcessTrusted(), args.count == 2, let key = UInt16(args[1]) else { fail("Accessibility access and key code required") }
    CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)?.post(tap: .cghidEventTap)
    usleep(40000)
    CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: false)?.post(tap: .cghidEventTap)
case "clipboard-save":
    guard args.count == 2 else { fail("path required") }
    let items = (pb.pasteboardItems ?? []).map { item -> [String: Data] in
        var data: [String: Data] = [:]
        for type in item.types { if let value = item.data(forType: type) { data[type.rawValue] = value } }
        return data
    }
    try PropertyListEncoder().encode(items).write(to: URL(fileURLWithPath: args[1]))
case "clipboard-restore":
    guard args.count == 2 else { fail("path required") }
    let saved = try PropertyListDecoder().decode([[String: Data]].self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
    let items = saved.map { values -> NSPasteboardItem in
        let item = NSPasteboardItem()
        for (type, data) in values { item.setData(data, forType: NSPasteboard.PasteboardType(type)) }
        return item
    }
    pb.clearContents(); if !items.isEmpty { pb.writeObjects(items) }
case "clipboard-count": print(pb.changeCount)
case "clipboard-read":
    guard args.count == 2, let text = pb.string(forType: .string) else { fail("text unavailable") }
    try text.write(toFile: args[1], atomically: true, encoding: .utf8)
default: fail("unknown command")
}
