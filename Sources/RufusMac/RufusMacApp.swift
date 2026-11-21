import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var onOpenURL: ((URL) -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        if let first = urls.first {
            onOpenURL?(first)
        }
    }
}

@main
struct RufusMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var vm = AppViewModel()

    var body: some Scene {
        WindowGroup("RufusMac") {
            MainView(vm: vm)
                .onAppear {
                    appDelegate.onOpenURL = { url in
                        Task { @MainActor in
                            vm.selectISO(url: url)
                        }
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 620, height: 770)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(vm.t("ISO / Image öffnen…", "Open ISO / Image…")) {
                    vm.openISOFilePicker()
                }
                .keyboardShortcut("o", modifiers: .command)
                .disabled(vm.isRunning)

                Button(vm.t("Laufwerke neu erkennen", "Rescan USB Drives")) {
                    vm.refreshDrives()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(vm.isRunning)

                Divider()

                Button(vm.t("Protokoll umschalten", "Toggle Log Drawer")) {
                    withAnimation {
                        vm.showLogDrawer.toggle()
                    }
                }
                .keyboardShortcut("l", modifiers: .command)
            }
        }
    }
}
