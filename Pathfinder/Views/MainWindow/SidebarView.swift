import SwiftUI

struct SidebarView: View {
    @Environment(QueueManager.self) private var queueManager
    @Environment(PresetManager.self) private var presetManager
    
    var body: some View {
        List {
            Section("Downloads") {
                Label("Active", systemImage: "arrow.down.circle")
                    .badge(queueManager.activeCount)
                Label("Queue", systemImage: "list.bullet")
                    .badge(queueManager.items.count)
            }
            
            Section("Presets") {
                ForEach(presetManager.presets) { preset in
                    Label(preset.name, systemImage: preset.icon)
                }
            }
        }
        .navigationTitle("Pathfinder")
    }
}
