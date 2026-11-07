import AppKit
import Carbon.HIToolbox
import Foundation

/// 全局快捷键：⌃⌥W 呼出菜单 / ⌃⌥D 显示隐藏 / ⌃⌥R 立即刷新。
///
/// 多屏 + 第三方菜单栏管理器（Bartender / Hidden Bar 之类）常常把新状态项折叠起来，
/// 甚至放到副屏菜单栏。快捷键是不受这些影响的稳定入口，也不依赖辅助功能权限。
enum HotKeys {
    private final class Box: @unchecked Sendable {
        var action: ((Int) -> Void)?
    }
    private static let box = Box()
    private static var refs: [EventHotKeyRef?] = []
    private static var handlerRef: EventHandlerRef?

    static func install(_ action: @escaping (Int) -> Void) {
        box.action = action

        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event,
                              EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID),
                              nil,
                              MemoryLayout<EventHotKeyID>.size,
                              nil,
                              &hk)
            let id = Int(hk.id)
            DispatchQueue.main.async { HotKeys.box.action?(id) }
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, nil, &handlerRef)

        let mods = UInt32(controlKey | optionKey)
        register(id: 1, key: UInt32(kVK_ANSI_W), mods: mods)  // 呼出菜单
        register(id: 2, key: UInt32(kVK_ANSI_D), mods: mods)  // 显示 / 隐藏
        register(id: 3, key: UInt32(kVK_ANSI_R), mods: mods)  // 立即刷新
    }

    private static func register(id: UInt32, key: UInt32, mods: UInt32) {
        let hotKeyID = EventHotKeyID(signature: OSType(0x5744534B), id: id) // 'WDSK'
        var ref: EventHotKeyRef?
        RegisterEventHotKey(key, mods, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        refs.append(ref)
    }
}
