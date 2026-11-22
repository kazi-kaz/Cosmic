#!/usr/bin/env python3
"""Mouse options and the keyboard built-in, compiled on the host (no iOS SDK).

Compiles the Foundation-only blocks: ControlAction/TouchControl (ContentView.swift),
the pure touch and preset state, MouseButton and MouseTuning (HardwareInput.swift's
pure section). Checks that the middle-click and scroll actions round-trip and that
layouts saved before them still decode, that MouseTuning's defaults leave motion and
buttons as they were, and that the built-in WASD keyboard layout has every control,
a look zone, and no overlaps on phones and tablets. Set SWIFTC if Swift is not on PATH.
"""
from pathlib import Path
import os
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
app = root / 'app/Madeira'
content = (app / 'ContentView.swift').read_text()
touch = (app / 'TouchGamepad.swift').read_text()
presets = (app / 'TouchControlPresets.swift').read_text()
hw = (app / 'HardwareInput.swift').read_text()

actions = content[content.index('enum ControlAction: Codable'):content.index('final class TouchControlsModel')]
pure_touch = touch.split('// MARK: - Pure touch state', 1)[1].split('// MARK: - UIKit touch lifetime', 1)[0]
pure_touch = pure_touch[pure_touch.index('struct GamepadSample'):]
pure = presets.split('// MARK: - Pure preset state', 1)[1].split('// MARK: - Persistence', 1)[0]
pure = pure[pure.index('struct ControlPreset'):]
button = hw[hw.index('enum MouseButton: Int'):hw.index('/// What has been posted DOWN')]
tuning = hw[hw.index('struct MouseTuning'):hw.index('// MARK: - Device glue')]

tests = r'''
var failures = 0
func require(_ condition: @autoclosure () -> Bool, _ label: String) {
    if condition() { print("PASS: " + label) } else { print("FAIL: " + label); failures += 1 }
}

// --- New actions round-trip; old saved layouts still decode.
let news: [ControlAction] = [.mouseMiddle, .scrollUp, .scrollDown]
for a in news {
    let data = try! JSONEncoder().encode(TouchControl(nx: 0.1, ny: 0.2, scale: 1, action: a))
    require(try! JSONDecoder().decode(TouchControl.self, from: data).action == a, "\(a) round-trips")
}
let oldJSON = #"[{"id":"6F1B5E2A-1C1D-4B7E-9C84-0A0B0C0D0E0F","nx":0.5,"ny":0.5,"scale":1,"action":{"mouseLeft":{}}},{"id":"7F1B5E2A-1C1D-4B7E-9C84-0A0B0C0D0E0F","nx":0.5,"ny":0.5,"scale":1,"action":{"key":{"_0":32}}}]"#
let old = try! JSONDecoder().decode([TouchControl].self, from: Data(oldJSON.utf8))
require(old[0].action == .mouseLeft && old[1].action == .key(32), "layouts saved before the new actions decode")
require(ControlAction.scrollUp.wheelDelta == 120 && ControlAction.scrollDown.wheelDelta == UInt32(bitPattern: -120)
        && ControlAction.mouseLeft.wheelDelta == 0, "scroll actions send one notch each way")

// --- MouseTuning: defaults are today's behaviour.
let none = MouseTuning { _ in nil }
require(none == MouseTuning() && none.speed == 1 && none.stickSpeed == 1 && !none.invertY && !none.swapButtons, "unset means as before")
require(none.yFactor == 1 && none.swapped(0x2) == 0x2 && none.swapped(.left) == .left, "defaults change nothing")
let set = MouseTuning { ["MADEIRA_MOUSE_SPEED": "1.5", "MADEIRA_STICK_MOUSE_SPEED": "0.5",
                         "MADEIRA_MOUSE_INVERT_Y": "1", "MADEIRA_MOUSE_SWAP_BUTTONS": "1"][$0] }
require(set.speed == 1.5 && set.stickSpeed == 0.5 && set.invertY && set.swapButtons && set.yFactor == -1, "lines are read")
require(MouseTuning { $0 == "MADEIRA_MOUSE_SPEED" ? "99" : nil }.speed == 4 && MouseTuning { $0 == "MADEIRA_MOUSE_SPEED" ? "0" : nil }.speed == 0.1
        && MouseTuning { $0 == "MADEIRA_MOUSE_SPEED" ? "abc" : nil }.speed == 1, "speed is clamped, junk is 1")
require(set.swapped(0x2) == 0x8 && set.swapped(0x4) == 0x10 && set.swapped(0x8) == 0x2 && set.swapped(0x10) == 0x4, "left and right bits swap")
require(set.swapped(0x8001) == 0x8001 && set.swapped(0x0800) == 0x0800 && set.swapped(0x20) == 0x20, "move, wheel and middle are kept")
require(set.swapped(.left) == .right && set.swapped(.right) == .left && set.swapped(.middle) == .middle, "buttons swap")

// --- The WASD keyboard built-in.
let screens: [(String, ControlPresetScreen)] = [
    ("6.3in phone", ControlPresetScreen(width: 874, height: 402, left: 59, right: 59, top: 0, bottom: 21)),
    ("6.1in phone", ControlPresetScreen(width: 844, height: 390, left: 47, right: 47, top: 0, bottom: 21)),
    ("4.7in phone", ControlPresetScreen(width: 667, height: 375)),
    ("11in tablet", ControlPresetScreen(width: 1194, height: 834, top: 24, bottom: 20)),
    ("13in tablet", ControlPresetScreen(width: 1366, height: 1024, top: 24, bottom: 20)),
    ("phone, portrait", ControlPresetScreen(width: 402, height: 874, top: 62, bottom: 34)),
]
let want: [ControlAction] = [.joystickWASD, .key(0x10), .key(0x11), .key(0x1B), .key(0x09), .key(0x20), .key(0x45),
                             .key(0x46), .key(0x0D), .mouseLeft, .mouseRight]
for (label, screen) in screens {
    let s = screen.landscape
    let cs = ControlPresetLayout.wasd(for: screen)
    require(cs.count == want.count && want.allSatisfy { a in cs.filter { $0.action == a }.count == 1 },
            "\(label): WASD stick, Space, E, F, Enter, L and R click, Shift, Ctrl, Esc, Tab once each")
    let boxes = cs.map { ControlPresetLayout.box($0, screen: s) }
    let m = ControlPresetLayout.margins(s)
    let safe = CGRect(x: m.left, y: m.top, width: s.width - m.left - m.right, height: s.height - m.top - m.bottom)
    require(boxes.allSatisfy { safe.contains($0) }, "\(label): inside the safe area")
    var overlaps: [String] = []
    for i in cs.indices { for j in cs.indices where j > i {
        let a = boxes[i], b = boxes[j]
        let dx = a.midX - b.midX, dy = a.midY - b.midY
        let round = abs(a.width - a.height) < 1e-9 && abs(b.width - b.height) < 1e-9
        if round ? (dx * dx + dy * dy).squareRoot() < a.width / 2 + b.width / 2 + 2 : a.insetBy(dx: -1, dy: -1).intersects(b) {
            overlaps.append("\(cs[i].action.label)/\(cs[j].action.label)")
        }
    } }
    require(overlaps.isEmpty, "\(label): no two controls overlap \(overlaps)")
    require(!boxes.contains { $0.intersects(ControlPresetLayout.topBarRect(s)) }, "\(label): the overlay's top band stays free")
    func at(_ a: ControlAction) -> TouchControl { cs.first { $0.action == a }! }
    require(at(.key(0x1B)).nx < 0.2 && at(.key(0x1B)).ny < 0.2 && at(.key(0x09)).nx > 0.8 && at(.key(0x09)).ny < 0.2, "\(label): Esc and Tab in the top corners")
    require(at(.mouseLeft).nx > 0.8 && at(.mouseRight).nx > 0.8, "\(label): clicks at the right edge")
    require(at(.key(0x10)).nx < 0.3 && at(.key(0x11)).nx < 0.4 && at(.joystickWASD).nx < 0.3, "\(label): stick, Shift and Ctrl on the left")
    require(cs.allSatisfy { $0.scale >= 0.5 && $0.scale <= 3.0 }, "\(label): scales inside the pinch clamp")
}
let builtIn = ControlPresetStore.builtIns.first { $0.id == ControlPresetLayout.wasdID }!
require(builtIn.zones?.count == 1 && builtIn.zones![0].kind == .look && builtIn.zones![0].x >= 0.5
        && builtIn.zones![0].x + builtIn.zones![0].w <= 1, "the built-in has a look zone over the right half")
let tablet = screens[3].1
require(ControlPresetStore.layout(of: builtIn, screen: tablet).map { $0.action } == ControlPresetLayout.wasd(for: tablet).map { $0.action },
        "the built-in is laid out again for the screen it is loaded on")

if failures > 0 { print("\(failures) FAILED"); exit(1) }
print("PASS: mouse options and the WASD keyboard layout")
'''

with tempfile.TemporaryDirectory(prefix='madeira-mouse-') as tmp:
    src, exe = Path(tmp) / 'main.swift', Path(tmp) / 'check'
    header = 'import Foundation\n#if canImport(CoreGraphics)\nimport CoreGraphics\n#endif\n'
    src.write_text(header + actions + pure_touch + pure + button + tuning + tests)
    subprocess.run([os.environ.get('SWIFTC', 'swiftc'), str(src), '-o', str(exe)], check=True)
    subprocess.run([str(exe)], check=True)
