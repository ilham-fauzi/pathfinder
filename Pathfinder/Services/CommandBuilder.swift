import Foundation
import SwiftUI

@Observable
class CommandBuilder {
    var options: DownloadOptions
    var url: String
    var outputDir: String
    
    init(options: DownloadOptions, url: String, outputDir: String) {
        self.options = options
        self.url = url
        self.outputDir = outputDir
    }
    
    /// Generate the full CLI command string for preview
    var cliPreview: String {
        let args = buildArgs()
        var formatted = "yt-dlp \\\n  "
        var currentChunk = [String]()
        
        for arg in args {
            currentChunk.append(arg)
            if currentChunk.count >= 2 && arg.hasPrefix("-") == false {
                formatted += currentChunk.joined(separator: " ") + " \\\n  "
                currentChunk.removeAll()
            }
        }
        
        if !currentChunk.isEmpty {
            formatted += currentChunk.joined(separator: " ")
        }
        
        return formatted.trimmingCharacters(in: CharacterSet(charactersIn: " \\\n"))
    }
    
    /// Generate as single line
    var cliSingleLine: String {
        let args = ["yt-dlp"] + buildArgs()
        return args.joined(separator: " ")
    }
    
    /// Generate as shell script content
    var shellScript: String {
        return "#!/bin/bash\n\n\(cliSingleLine)\n"
    }
    
    private func buildArgs() -> [String] {
        var args = options.toArgs()
        args.append(contentsOf: ["-P", "\"\(outputDir)\""])
        args.append("\"\(url)\"")
        return args
    }
    
    /// Parse a CLI command string back into DownloadOptions (reverse)
    static func parse(cliString: String) -> (url: String, options: DownloadOptions)? {
        // Advanced parsing logic would go here
        return nil
    }
}
