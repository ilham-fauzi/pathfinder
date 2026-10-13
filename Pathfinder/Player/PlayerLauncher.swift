import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The file pickers and refusal dialogs of the player.
@MainActor
enum PlayerLauncher {
    /// Pick one or more files. A disguised file can't be filtered by type, so any file is selectable once the setting is on.
    static func chooseFiles(model: PlayerModel, playNow: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = model.settings.playDisguisedVideos ? [.data] : [.movie, .audio]
        panel.directoryURL = URL(fileURLWithPath: model.settings.defaultOutputDir)
        panel.message = "Choose videos or audio files"
        guard panel.runModal() == .OK else { return }
        model.addURLs(panel.urls, playNow: playNow)
    }

    /// Pick folders: everything inside is added when it turns out to be a video, whatever its extension.
    static func chooseFolder(model: PlayerModel, playNow: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: model.settings.defaultOutputDir)
        panel.message = "Choose a folder of videos"
        guard panel.runModal() == .OK else { return }
        model.addURLs(panel.urls, playNow: playNow)
    }

    static func openSettings() {
        SettingsTab.open(.player)
    }

    /// One file was refused: say why, and offer the fix when there is one.
    static func explain(_ reason: PlayerGate.Decision, for url: URL, model: PlayerModel) {
        switch reason {
        case .disabled:
            alert("This file isn't a video by its name",
                  "If it is a video saved under another extension, turn on “Play videos with a different extension” in Settings › Player.",
                  action: ("Open Settings", openSettings))
        case .notAllowed(let ext):
            alert("“.\(ext)” isn't on the list",
                  "The player only looks inside files with the extensions you allowed. Add “.\(ext)” to try this one.",
                  action: ("Add .\(ext)", {
                      model.settings.allowDisguisedExtension(ext)
                      model.addURLs([url], playNow: true)
                  }))
        case .notMedia:
            alert("Not a supported video file",
                  "The content isn't a video or audio file the player recognises. It may be a document, damaged, or encrypted.",
                  action: nil)
        case .missing:
            alert("File not found", "The file was moved or deleted.", action: nil)
        case .play:
            break
        }
    }

    private static func alert(_ title: String, _ message: String, action: (String, () -> Void)?) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let action { alert.addButton(withTitle: action.0) }
        alert.addButton(withTitle: action == nil ? "OK" : "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, let action { action.1() }
    }
}

struct PlayerCommands: Commands {
    let model: PlayerModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Open Video…") { PlayerLauncher.chooseFiles(model: model, playNow: true) }
                .keyboardShortcut("o")
            Button("Open Video Folder…") { PlayerLauncher.chooseFolder(model: model, playNow: true) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
        }
    }
}
