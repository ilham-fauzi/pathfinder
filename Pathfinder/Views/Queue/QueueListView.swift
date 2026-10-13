import SwiftUI

struct QueueListView: View {
    @Environment(QueueManager.self) private var queueManager
    
    var body: some View {
        VStack {
            HStack {
                Text("Active: \(queueManager.activeCount) / Total: \(queueManager.items.count)")
                    .font(.headline)
                Spacer()
                Button("Clear Completed") { queueManager.clearCompleted() }
            }
            .padding()
            
            if queueManager.items.isEmpty {
                Spacer()
                Text("No downloads yet")
                    .foregroundColor(.secondary)
                    .font(.title2)
                Spacer()
            } else {
                List {
                    ForEach(queueManager.items) { item in
                        QueueItemRow(item: item)
                    }
                }
            }
        }
    }
}
