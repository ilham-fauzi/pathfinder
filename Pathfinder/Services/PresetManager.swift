import Foundation
import SwiftUI

@Observable
class PresetManager {
    private(set) var presets: [Preset] = []
    private let presetsURL: URL
    
    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        presetsURL = appSupport.appendingPathComponent("Pathfinder/presets")
        
        try? FileManager.default.createDirectory(at: presetsURL, withIntermediateDirectories: true)
        loadPresets()
    }
    
    private func loadPresets() {
        // Load default/bundled
        // Load custom from presetsURL
    }
    
    func save(_ preset: Preset) throws {
        let data = try JSONEncoder().encode(preset)
        let fileURL = presetsURL.appendingPathComponent("\(preset.id.uuidString).json")
        try data.write(to: fileURL)
        
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
        } else {
            presets.append(preset)
        }
    }
    
    func delete(_ preset: Preset) throws {
        let fileURL = presetsURL.appendingPathComponent("\(preset.id.uuidString).json")
        try FileManager.default.removeItem(at: fileURL)
        presets.removeAll { $0.id == preset.id }
    }
    
    func update(_ preset: Preset) throws {
        try save(preset)
    }
    
    func exportPreset(_ preset: Preset, to url: URL) throws {
        let data = try JSONEncoder().encode(preset)
        try data.write(to: url)
    }
    
    func importPreset(from url: URL) throws -> Preset {
        let data = try Data(contentsOf: url)
        let preset = try JSONDecoder().decode(Preset.self, from: data)
        try save(preset)
        return preset
    }
    
    func applyPreset(_ preset: Preset, to options: inout DownloadOptions) {
        options = preset.options
    }
}
