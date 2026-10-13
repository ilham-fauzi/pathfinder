import Foundation

struct Preset: Codable, Identifiable {
    let id: UUID
    var name: String
    var description: String
    var icon: String
    var options: DownloadOptions
    var isBuiltIn: Bool
    var createdAt: Date
    
    static var builtInPresets: [Preset] {
        [
        Preset(id: UUID(), name: "Best Video", description: "Best available video and audio", icon: "video.fill", options: {
            let opt = DownloadOptions()
            opt.format = "bv*+ba/b"
            return opt
        }(), isBuiltIn: true, createdAt: Date()),
        
        Preset(id: UUID(), name: "1080p MP4", description: "1080p video in MP4 format", icon: "tv", options: {
            let opt = DownloadOptions()
            opt.format = "bv*[height<=1080][ext=mp4]+ba[ext=m4a]/b[ext=mp4]/b"
            opt.mergeOutputFormat = .mp4
            return opt
        }(), isBuiltIn: true, createdAt: Date()),
        
        Preset(id: UUID(), name: "720p MP4", description: "720p video in MP4 format", icon: "tv.fill", options: {
            let opt = DownloadOptions()
            opt.format = "bv*[height<=720][ext=mp4]+ba[ext=m4a]/b[ext=mp4]/b"
            opt.mergeOutputFormat = .mp4
            return opt
        }(), isBuiltIn: true, createdAt: Date()),
        
        Preset(id: UUID(), name: "Audio MP3 320k", description: "High quality MP3 audio", icon: "music.note", options: {
            let opt = DownloadOptions()
            opt.extractAudio = true
            opt.audioFormat = .mp3
            opt.audioQuality = 0
            return opt
        }(), isBuiltIn: true, createdAt: Date()),
        
        Preset(id: UUID(), name: "Audio FLAC", description: "Lossless FLAC audio", icon: "waveform", options: {
            let opt = DownloadOptions()
            opt.extractAudio = true
            opt.audioFormat = .flac
            return opt
        }(), isBuiltIn: true, createdAt: Date()),
        
        Preset(id: UUID(), name: "Audio Opus", description: "Efficient Opus audio", icon: "speaker.wave.3", options: {
            let opt = DownloadOptions()
            opt.extractAudio = true
            opt.audioFormat = .opus
            return opt
        }(), isBuiltIn: true, createdAt: Date()),
        
        Preset(id: UUID(), name: "Podcast", description: "MP3 with thumbnail and metadata", icon: "mic.fill", options: {
            let opt = DownloadOptions()
            opt.extractAudio = true
            opt.audioFormat = .mp3
            opt.embedThumbnail = true
            opt.embedMetadata = true
            return opt
        }(), isBuiltIn: true, createdAt: Date()),
        
        Preset(id: UUID(), name: "Archival", description: "Download with all possible metadata", icon: "archivebox", options: {
            let opt = DownloadOptions()
            opt.embedSubs = true
            opt.embedThumbnail = true
            opt.embedMetadata = true
            opt.embedChapters = true
            opt.embedInfoJson = true
            opt.writeDescription = true
            opt.writeComments = true
            opt.writeSubs = true
            opt.writeAutoSubs = true
            return opt
        }(), isBuiltIn: true, createdAt: Date()),
        
        Preset(id: UUID(), name: "Playlist Sequential", description: "Download playlist items sequentially", icon: "list.number", options: {
            let opt = DownloadOptions()
            opt.outputTemplate = "%(playlist_index)s - %(title)s [%(id)s].%(ext)s"
            opt.noPlaylist = false
            return opt
        }(), isBuiltIn: true, createdAt: Date()),
        
        Preset(id: UUID(), name: "No Sponsor", description: "Remove sponsorblock segments", icon: "play.slash.fill", options: {
            let opt = DownloadOptions()
            opt.sponsorblockRemove = ["sponsor", "intro", "outro"]
            return opt
        }(), isBuiltIn: true, createdAt: Date())
        ]
    }
}
