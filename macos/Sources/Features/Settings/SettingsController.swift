import Foundation
import Cocoa
import SwiftUI
import GhosttyKit

class SettingsController: NSWindowController, NSWindowDelegate {
    static let shared: SettingsController = SettingsController()

    override var windowNibName: NSNib.Name? { "Settings" }

    override func windowDidLoad() {
        guard let window = window else { return }
        window.center()
        window.title = "Settings"
        window.contentView = NSHostingView(rootView: SettingsView())
    }

    // MARK: - Functions

    func show() {
        window?.makeKeyAndOrderFront(nil)
    }

    func hide() {
        window?.close()
    }

    // MARK: - First Responder

    @IBAction func close(_ sender: Any) {
        self.window?.performClose(sender)
    }

    @IBAction func closeWindow(_ sender: Any) {
        self.window?.performClose(sender)
    }

    // This is called when "escape" is pressed.
    @objc func cancel(_ sender: Any?) {
        close()
    }
}
