import Foundation
import SwiftUI

enum MergeFormat: String, Codable {
    case mp4, mkv, webm, flv, mov, avi
}

enum AudioFormat: String, Codable {
    case best, mp3, aac, m4a, opus, vorbis, flac, alac, wav
}

@Observable
// Marked @unchecked Sendable: this is a plain UI-editable options bag. It is only ever
// mutated on the main actor and is read into an immutable [String] (via toArgs()) the
// moment it is handed to the download actor, so no shared mutable state actually crosses
// the actor boundary.
final class DownloadOptions: Codable, @unchecked Sendable {
    private enum CodingKeys: String, CodingKey {
        case format
        case formatSort
        case formatSortForce
        case mergeOutputFormat
        case recodeVideo
        case remuxVideo
        case preferFreeFormats
        case checkFormats
        case audioMultistreams
        case videoMultistreams
        case extractAudio
        case audioFormat
        case audioQuality
        case audioBitrate
        case embedSubs
        case embedThumbnail
        case embedMetadata
        case embedChapters
        case embedInfoJson
        case sponsorblockMark
        case sponsorblockRemove
        case convertSubs
        case convertThumbnails
        case fixup
        case ffmpegLocation
        case postprocessorArgs
        case execCommand
        case splitChapters
        case removeChapters
        case forceKeyframesAtCuts
        case keepVideo
        case noPostOverwrites
        case writeSubs
        case writeAutoSubs
        case subLangs
        case subFormat
        case proxy
        case socketTimeout
        case sourceAddress
        case forceIPv4
        case forceIPv6
        case impersonate
        case geoVerificationProxy
        case xff
        case username
        case password
        case twofactor
        case videoPassword
        case netrc
        case netrcLocation
        case cookiesFile
        case cookiesFromBrowser
        case outputTemplate
        case outputNaPlaceholder
        case paths
        case tempPath
        case restrictFilenames
        case windowsFilenames
        case trimFilenames
        case noOverwrites
        case forceOverwrites
        case continueDownload
        case usePart
        case useMtime
        case writeDescription
        case writeInfoJson
        case writeComments
        case cleanInfoJson
        case downloadArchive
        case batchFile
        case concurrentFragments
        case limitRate
        case throttledRate
        case retries
        case fragmentRetries
        case retrySleep
        case bufferSize
        case httpChunkSize
        case downloader
        case downloaderArgs
        case hlsUseMpegts
        case downloadSections
        case playlistItems
        case minFilesize
        case maxFilesize
        case dateFilter
        case dateBeforeFilter
        case dateAfterFilter
        case matchFilters
        case ageLimit
        case maxDownloads
        case noPlaylist
        case playlistRandom
        case breakOnExisting
        case liveFromStart
        case waitForVideo
        case verbose
        case quiet
        case simulate
        case userAgent
        case referer
        case customHeaders
        case sleepInterval
        case maxSleepInterval
        case sleepRequests
        case noCheckCertificates
        case legacyServerConnect
        case extractorArgs
        case useExtractors
        case defaultSearch
        case markWatched
        case flatPlaylist
        case ignoreErrors
    }

    init() {}

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.format = try container.decodeIfPresent(String.self, forKey: .format)
        self.formatSort = try container.decodeIfPresent(String.self, forKey: .formatSort)
        self.formatSortForce = try container.decodeIfPresent(Bool.self, forKey: .formatSortForce) ?? false
        self.mergeOutputFormat = try container.decodeIfPresent(MergeFormat.self, forKey: .mergeOutputFormat)
        self.recodeVideo = try container.decodeIfPresent(String.self, forKey: .recodeVideo)
        self.remuxVideo = try container.decodeIfPresent(String.self, forKey: .remuxVideo)
        self.preferFreeFormats = try container.decodeIfPresent(Bool.self, forKey: .preferFreeFormats) ?? false
        self.checkFormats = try container.decodeIfPresent(Bool.self, forKey: .checkFormats) ?? false
        self.audioMultistreams = try container.decodeIfPresent(Bool.self, forKey: .audioMultistreams) ?? false
        self.videoMultistreams = try container.decodeIfPresent(Bool.self, forKey: .videoMultistreams) ?? false
        self.extractAudio = try container.decodeIfPresent(Bool.self, forKey: .extractAudio) ?? false
        self.audioFormat = try container.decodeIfPresent(AudioFormat.self, forKey: .audioFormat)
        self.audioQuality = try container.decodeIfPresent(Int.self, forKey: .audioQuality) ?? 5
        self.audioBitrate = try container.decodeIfPresent(String.self, forKey: .audioBitrate)
        self.embedSubs = try container.decodeIfPresent(Bool.self, forKey: .embedSubs) ?? true
        self.embedThumbnail = try container.decodeIfPresent(Bool.self, forKey: .embedThumbnail) ?? true
        self.embedMetadata = try container.decodeIfPresent(Bool.self, forKey: .embedMetadata) ?? true
        self.embedChapters = try container.decodeIfPresent(Bool.self, forKey: .embedChapters) ?? true
        self.embedInfoJson = try container.decodeIfPresent(Bool.self, forKey: .embedInfoJson) ?? false
        self.sponsorblockMark = try container.decodeIfPresent([String].self, forKey: .sponsorblockMark) ?? []
        self.sponsorblockRemove = try container.decodeIfPresent([String].self, forKey: .sponsorblockRemove) ?? []
        self.convertSubs = try container.decodeIfPresent(String.self, forKey: .convertSubs)
        self.convertThumbnails = try container.decodeIfPresent(String.self, forKey: .convertThumbnails)
        self.fixup = try container.decodeIfPresent(String.self, forKey: .fixup)
        self.ffmpegLocation = try container.decodeIfPresent(String.self, forKey: .ffmpegLocation)
        self.postprocessorArgs = try container.decodeIfPresent(String.self, forKey: .postprocessorArgs)
        self.execCommand = try container.decodeIfPresent(String.self, forKey: .execCommand)
        self.splitChapters = try container.decodeIfPresent(Bool.self, forKey: .splitChapters) ?? false
        self.removeChapters = try container.decodeIfPresent(String.self, forKey: .removeChapters)
        self.forceKeyframesAtCuts = try container.decodeIfPresent(Bool.self, forKey: .forceKeyframesAtCuts) ?? false
        self.keepVideo = try container.decodeIfPresent(Bool.self, forKey: .keepVideo) ?? false
        self.noPostOverwrites = try container.decodeIfPresent(Bool.self, forKey: .noPostOverwrites) ?? false
        self.writeSubs = try container.decodeIfPresent(Bool.self, forKey: .writeSubs) ?? false
        self.writeAutoSubs = try container.decodeIfPresent(Bool.self, forKey: .writeAutoSubs) ?? false
        self.subLangs = try container.decodeIfPresent(String.self, forKey: .subLangs)
        self.subFormat = try container.decodeIfPresent(String.self, forKey: .subFormat)
        self.proxy = try container.decodeIfPresent(String.self, forKey: .proxy)
        self.socketTimeout = try container.decodeIfPresent(Int.self, forKey: .socketTimeout)
        self.sourceAddress = try container.decodeIfPresent(String.self, forKey: .sourceAddress)
        self.forceIPv4 = try container.decodeIfPresent(Bool.self, forKey: .forceIPv4) ?? false
        self.forceIPv6 = try container.decodeIfPresent(Bool.self, forKey: .forceIPv6) ?? false
        self.impersonate = try container.decodeIfPresent(String.self, forKey: .impersonate)
        self.geoVerificationProxy = try container.decodeIfPresent(String.self, forKey: .geoVerificationProxy)
        self.xff = try container.decodeIfPresent(String.self, forKey: .xff)
        self.username = try container.decodeIfPresent(String.self, forKey: .username)
        self.password = try container.decodeIfPresent(String.self, forKey: .password)
        self.twofactor = try container.decodeIfPresent(String.self, forKey: .twofactor)
        self.videoPassword = try container.decodeIfPresent(String.self, forKey: .videoPassword)
        self.netrc = try container.decodeIfPresent(Bool.self, forKey: .netrc) ?? false
        self.netrcLocation = try container.decodeIfPresent(String.self, forKey: .netrcLocation)
        self.cookiesFile = try container.decodeIfPresent(String.self, forKey: .cookiesFile)
        self.cookiesFromBrowser = try container.decodeIfPresent(String.self, forKey: .cookiesFromBrowser)
        self.outputTemplate = try container.decodeIfPresent(String.self, forKey: .outputTemplate) ?? "%(title)s [%(id)s].%(ext)s"
        self.outputNaPlaceholder = try container.decodeIfPresent(String.self, forKey: .outputNaPlaceholder)
        self.paths = try container.decodeIfPresent(String.self, forKey: .paths)
        self.tempPath = try container.decodeIfPresent(String.self, forKey: .tempPath)
        self.restrictFilenames = try container.decodeIfPresent(Bool.self, forKey: .restrictFilenames) ?? false
        self.windowsFilenames = try container.decodeIfPresent(Bool.self, forKey: .windowsFilenames) ?? false
        self.trimFilenames = try container.decodeIfPresent(Int.self, forKey: .trimFilenames)
        self.noOverwrites = try container.decodeIfPresent(Bool.self, forKey: .noOverwrites) ?? false
        self.forceOverwrites = try container.decodeIfPresent(Bool.self, forKey: .forceOverwrites) ?? false
        self.continueDownload = try container.decodeIfPresent(Bool.self, forKey: .continueDownload) ?? true
        self.usePart = try container.decodeIfPresent(Bool.self, forKey: .usePart) ?? true
        self.useMtime = try container.decodeIfPresent(Bool.self, forKey: .useMtime) ?? false
        self.writeDescription = try container.decodeIfPresent(Bool.self, forKey: .writeDescription) ?? false
        self.writeInfoJson = try container.decodeIfPresent(Bool.self, forKey: .writeInfoJson) ?? false
        self.writeComments = try container.decodeIfPresent(Bool.self, forKey: .writeComments) ?? false
        self.cleanInfoJson = try container.decodeIfPresent(Bool.self, forKey: .cleanInfoJson) ?? true
        self.downloadArchive = try container.decodeIfPresent(String.self, forKey: .downloadArchive)
        self.batchFile = try container.decodeIfPresent(String.self, forKey: .batchFile)
        self.concurrentFragments = try container.decodeIfPresent(Int.self, forKey: .concurrentFragments) ?? 1
        self.limitRate = try container.decodeIfPresent(String.self, forKey: .limitRate)
        self.throttledRate = try container.decodeIfPresent(String.self, forKey: .throttledRate)
        self.retries = try container.decodeIfPresent(Int.self, forKey: .retries) ?? 10
        self.fragmentRetries = try container.decodeIfPresent(Int.self, forKey: .fragmentRetries) ?? 10
        self.retrySleep = try container.decodeIfPresent(String.self, forKey: .retrySleep)
        self.bufferSize = try container.decodeIfPresent(String.self, forKey: .bufferSize)
        self.httpChunkSize = try container.decodeIfPresent(String.self, forKey: .httpChunkSize)
        self.downloader = try container.decodeIfPresent(String.self, forKey: .downloader)
        self.downloaderArgs = try container.decodeIfPresent(String.self, forKey: .downloaderArgs)
        self.hlsUseMpegts = try container.decodeIfPresent(Bool.self, forKey: .hlsUseMpegts) ?? false
        self.downloadSections = try container.decodeIfPresent(String.self, forKey: .downloadSections)
        self.playlistItems = try container.decodeIfPresent(String.self, forKey: .playlistItems)
        self.minFilesize = try container.decodeIfPresent(String.self, forKey: .minFilesize)
        self.maxFilesize = try container.decodeIfPresent(String.self, forKey: .maxFilesize)
        self.dateFilter = try container.decodeIfPresent(String.self, forKey: .dateFilter)
        self.dateBeforeFilter = try container.decodeIfPresent(String.self, forKey: .dateBeforeFilter)
        self.dateAfterFilter = try container.decodeIfPresent(String.self, forKey: .dateAfterFilter)
        self.matchFilters = try container.decodeIfPresent(String.self, forKey: .matchFilters)
        self.ageLimit = try container.decodeIfPresent(Int.self, forKey: .ageLimit)
        self.maxDownloads = try container.decodeIfPresent(Int.self, forKey: .maxDownloads)
        self.noPlaylist = try container.decodeIfPresent(Bool.self, forKey: .noPlaylist) ?? false
        self.playlistRandom = try container.decodeIfPresent(Bool.self, forKey: .playlistRandom) ?? false
        self.breakOnExisting = try container.decodeIfPresent(Bool.self, forKey: .breakOnExisting) ?? false
        self.liveFromStart = try container.decodeIfPresent(Bool.self, forKey: .liveFromStart) ?? false
        self.waitForVideo = try container.decodeIfPresent(String.self, forKey: .waitForVideo)
        self.verbose = try container.decodeIfPresent(Bool.self, forKey: .verbose) ?? false
        self.quiet = try container.decodeIfPresent(Bool.self, forKey: .quiet) ?? false
        self.simulate = try container.decodeIfPresent(Bool.self, forKey: .simulate) ?? false
        self.userAgent = try container.decodeIfPresent(String.self, forKey: .userAgent)
        self.referer = try container.decodeIfPresent(String.self, forKey: .referer)
        self.customHeaders = try container.decodeIfPresent([String: String].self, forKey: .customHeaders) ?? [:]
        self.sleepInterval = try container.decodeIfPresent(Int.self, forKey: .sleepInterval)
        self.maxSleepInterval = try container.decodeIfPresent(Int.self, forKey: .maxSleepInterval)
        self.sleepRequests = try container.decodeIfPresent(Double.self, forKey: .sleepRequests)
        self.noCheckCertificates = try container.decodeIfPresent(Bool.self, forKey: .noCheckCertificates) ?? false
        self.legacyServerConnect = try container.decodeIfPresent(Bool.self, forKey: .legacyServerConnect) ?? false
        self.extractorArgs = try container.decodeIfPresent([String: String].self, forKey: .extractorArgs) ?? [:]
        self.useExtractors = try container.decodeIfPresent(String.self, forKey: .useExtractors)
        self.defaultSearch = try container.decodeIfPresent(String.self, forKey: .defaultSearch)
        self.markWatched = try container.decodeIfPresent(Bool.self, forKey: .markWatched) ?? false
        self.flatPlaylist = try container.decodeIfPresent(Bool.self, forKey: .flatPlaylist) ?? false
        self.ignoreErrors = try container.decodeIfPresent(Bool.self, forKey: .ignoreErrors) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(format, forKey: .format)
        try container.encodeIfPresent(formatSort, forKey: .formatSort)
        try container.encode(formatSortForce, forKey: .formatSortForce)
        try container.encodeIfPresent(mergeOutputFormat, forKey: .mergeOutputFormat)
        try container.encodeIfPresent(recodeVideo, forKey: .recodeVideo)
        try container.encodeIfPresent(remuxVideo, forKey: .remuxVideo)
        try container.encode(preferFreeFormats, forKey: .preferFreeFormats)
        try container.encode(checkFormats, forKey: .checkFormats)
        try container.encode(audioMultistreams, forKey: .audioMultistreams)
        try container.encode(videoMultistreams, forKey: .videoMultistreams)
        try container.encode(extractAudio, forKey: .extractAudio)
        try container.encodeIfPresent(audioFormat, forKey: .audioFormat)
        try container.encode(audioQuality, forKey: .audioQuality)
        try container.encodeIfPresent(audioBitrate, forKey: .audioBitrate)
        try container.encode(embedSubs, forKey: .embedSubs)
        try container.encode(embedThumbnail, forKey: .embedThumbnail)
        try container.encode(embedMetadata, forKey: .embedMetadata)
        try container.encode(embedChapters, forKey: .embedChapters)
        try container.encode(embedInfoJson, forKey: .embedInfoJson)
        try container.encode(sponsorblockMark, forKey: .sponsorblockMark)
        try container.encode(sponsorblockRemove, forKey: .sponsorblockRemove)
        try container.encodeIfPresent(convertSubs, forKey: .convertSubs)
        try container.encodeIfPresent(convertThumbnails, forKey: .convertThumbnails)
        try container.encodeIfPresent(fixup, forKey: .fixup)
        try container.encodeIfPresent(ffmpegLocation, forKey: .ffmpegLocation)
        try container.encodeIfPresent(postprocessorArgs, forKey: .postprocessorArgs)
        try container.encodeIfPresent(execCommand, forKey: .execCommand)
        try container.encode(splitChapters, forKey: .splitChapters)
        try container.encodeIfPresent(removeChapters, forKey: .removeChapters)
        try container.encode(forceKeyframesAtCuts, forKey: .forceKeyframesAtCuts)
        try container.encode(keepVideo, forKey: .keepVideo)
        try container.encode(noPostOverwrites, forKey: .noPostOverwrites)
        try container.encode(writeSubs, forKey: .writeSubs)
        try container.encode(writeAutoSubs, forKey: .writeAutoSubs)
        try container.encodeIfPresent(subLangs, forKey: .subLangs)
        try container.encodeIfPresent(subFormat, forKey: .subFormat)
        try container.encodeIfPresent(proxy, forKey: .proxy)
        try container.encodeIfPresent(socketTimeout, forKey: .socketTimeout)
        try container.encodeIfPresent(sourceAddress, forKey: .sourceAddress)
        try container.encode(forceIPv4, forKey: .forceIPv4)
        try container.encode(forceIPv6, forKey: .forceIPv6)
        try container.encodeIfPresent(impersonate, forKey: .impersonate)
        try container.encodeIfPresent(geoVerificationProxy, forKey: .geoVerificationProxy)
        try container.encodeIfPresent(xff, forKey: .xff)
        try container.encodeIfPresent(username, forKey: .username)
        try container.encodeIfPresent(password, forKey: .password)
        try container.encodeIfPresent(twofactor, forKey: .twofactor)
        try container.encodeIfPresent(videoPassword, forKey: .videoPassword)
        try container.encode(netrc, forKey: .netrc)
        try container.encodeIfPresent(netrcLocation, forKey: .netrcLocation)
        try container.encodeIfPresent(cookiesFile, forKey: .cookiesFile)
        try container.encodeIfPresent(cookiesFromBrowser, forKey: .cookiesFromBrowser)
        try container.encode(outputTemplate, forKey: .outputTemplate)
        try container.encodeIfPresent(outputNaPlaceholder, forKey: .outputNaPlaceholder)
        try container.encodeIfPresent(paths, forKey: .paths)
        try container.encodeIfPresent(tempPath, forKey: .tempPath)
        try container.encode(restrictFilenames, forKey: .restrictFilenames)
        try container.encode(windowsFilenames, forKey: .windowsFilenames)
        try container.encodeIfPresent(trimFilenames, forKey: .trimFilenames)
        try container.encode(noOverwrites, forKey: .noOverwrites)
        try container.encode(forceOverwrites, forKey: .forceOverwrites)
        try container.encode(continueDownload, forKey: .continueDownload)
        try container.encode(usePart, forKey: .usePart)
        try container.encode(useMtime, forKey: .useMtime)
        try container.encode(writeDescription, forKey: .writeDescription)
        try container.encode(writeInfoJson, forKey: .writeInfoJson)
        try container.encode(writeComments, forKey: .writeComments)
        try container.encode(cleanInfoJson, forKey: .cleanInfoJson)
        try container.encodeIfPresent(downloadArchive, forKey: .downloadArchive)
        try container.encodeIfPresent(batchFile, forKey: .batchFile)
        try container.encode(concurrentFragments, forKey: .concurrentFragments)
        try container.encodeIfPresent(limitRate, forKey: .limitRate)
        try container.encodeIfPresent(throttledRate, forKey: .throttledRate)
        try container.encode(retries, forKey: .retries)
        try container.encode(fragmentRetries, forKey: .fragmentRetries)
        try container.encodeIfPresent(retrySleep, forKey: .retrySleep)
        try container.encodeIfPresent(bufferSize, forKey: .bufferSize)
        try container.encodeIfPresent(httpChunkSize, forKey: .httpChunkSize)
        try container.encodeIfPresent(downloader, forKey: .downloader)
        try container.encodeIfPresent(downloaderArgs, forKey: .downloaderArgs)
        try container.encode(hlsUseMpegts, forKey: .hlsUseMpegts)
        try container.encodeIfPresent(downloadSections, forKey: .downloadSections)
        try container.encodeIfPresent(playlistItems, forKey: .playlistItems)
        try container.encodeIfPresent(minFilesize, forKey: .minFilesize)
        try container.encodeIfPresent(maxFilesize, forKey: .maxFilesize)
        try container.encodeIfPresent(dateFilter, forKey: .dateFilter)
        try container.encodeIfPresent(dateBeforeFilter, forKey: .dateBeforeFilter)
        try container.encodeIfPresent(dateAfterFilter, forKey: .dateAfterFilter)
        try container.encodeIfPresent(matchFilters, forKey: .matchFilters)
        try container.encodeIfPresent(ageLimit, forKey: .ageLimit)
        try container.encodeIfPresent(maxDownloads, forKey: .maxDownloads)
        try container.encode(noPlaylist, forKey: .noPlaylist)
        try container.encode(playlistRandom, forKey: .playlistRandom)
        try container.encode(breakOnExisting, forKey: .breakOnExisting)
        try container.encode(liveFromStart, forKey: .liveFromStart)
        try container.encodeIfPresent(waitForVideo, forKey: .waitForVideo)
        try container.encode(verbose, forKey: .verbose)
        try container.encode(quiet, forKey: .quiet)
        try container.encode(simulate, forKey: .simulate)
        try container.encodeIfPresent(userAgent, forKey: .userAgent)
        try container.encodeIfPresent(referer, forKey: .referer)
        try container.encode(customHeaders, forKey: .customHeaders)
        try container.encodeIfPresent(sleepInterval, forKey: .sleepInterval)
        try container.encodeIfPresent(maxSleepInterval, forKey: .maxSleepInterval)
        try container.encodeIfPresent(sleepRequests, forKey: .sleepRequests)
        try container.encode(noCheckCertificates, forKey: .noCheckCertificates)
        try container.encode(legacyServerConnect, forKey: .legacyServerConnect)
        try container.encode(extractorArgs, forKey: .extractorArgs)
        try container.encodeIfPresent(useExtractors, forKey: .useExtractors)
        try container.encodeIfPresent(defaultSearch, forKey: .defaultSearch)
        try container.encode(markWatched, forKey: .markWatched)
        try container.encode(flatPlaylist, forKey: .flatPlaylist)
        try container.encode(ignoreErrors, forKey: .ignoreErrors)
    }

    // MARK: - Format Options
    var format: String? = "bv*+ba/b"
    var formatSort: String?
    var formatSortForce: Bool = false
    var mergeOutputFormat: MergeFormat?
    var recodeVideo: String?
    var remuxVideo: String?
    var preferFreeFormats: Bool = false
    var checkFormats: Bool = false
    var audioMultistreams: Bool = false
    var videoMultistreams: Bool = false
    
    // MARK: - Audio Options
    var extractAudio: Bool = false
    var audioFormat: AudioFormat?
    var audioQuality: Int = 5
    /// Target bitrate such as "320K". Overrides `audioQuality` when set.
    var audioBitrate: String?
    
    // MARK: - Post-Processing
    var embedSubs: Bool = true
    var embedThumbnail: Bool = true
    var embedMetadata: Bool = true
    var embedChapters: Bool = true
    var embedInfoJson: Bool = false
    var sponsorblockMark: [String] = []
    var sponsorblockRemove: [String] = []
    var convertSubs: String?
    var convertThumbnails: String?
    var fixup: String? = "detect_or_warn"
    var ffmpegLocation: String?
    var postprocessorArgs: String?
    var execCommand: String?
    var splitChapters: Bool = false
    var removeChapters: String?
    var forceKeyframesAtCuts: Bool = false
    var keepVideo: Bool = false
    var noPostOverwrites: Bool = false
    
    // MARK: - Subtitle Options
    var writeSubs: Bool = false
    var writeAutoSubs: Bool = false
    var subLangs: String?
    var subFormat: String?
    
    // MARK: - Network & Auth
    var proxy: String?
    var socketTimeout: Int?
    var sourceAddress: String?
    var forceIPv4: Bool = false
    var forceIPv6: Bool = false
    var impersonate: String?
    var geoVerificationProxy: String?
    var xff: String?
    var username: String?
    var password: String?
    var twofactor: String?
    var videoPassword: String?
    var netrc: Bool = false
    var netrcLocation: String?
    var cookiesFile: String?
    var cookiesFromBrowser: String?
    
    // MARK: - Filesystem & Output
    var outputTemplate: String = "%(title)s [%(id)s].%(ext)s"
    var outputNaPlaceholder: String?
    var paths: String?
    var tempPath: String?
    var restrictFilenames: Bool = false
    var windowsFilenames: Bool = false
    var trimFilenames: Int?
    var noOverwrites: Bool = false
    var forceOverwrites: Bool = false
    var continueDownload: Bool = true
    var usePart: Bool = true
    var useMtime: Bool = false
    var writeDescription: Bool = false
    var writeInfoJson: Bool = false
    var writeComments: Bool = false
    var cleanInfoJson: Bool = true
    var downloadArchive: String?
    var batchFile: String?
    
    // MARK: - Download Control
    var concurrentFragments: Int = 1
    var limitRate: String?
    var throttledRate: String?
    var retries: Int = 10
    var fragmentRetries: Int = 10
    var retrySleep: String?
    var bufferSize: String?
    var httpChunkSize: String?
    var downloader: String?
    var downloaderArgs: String?
    var hlsUseMpegts: Bool = false
    var downloadSections: String?
    
    // MARK: - Video Selection
    var playlistItems: String?
    var minFilesize: String?
    var maxFilesize: String?
    var dateFilter: String?
    var dateBeforeFilter: String?
    var dateAfterFilter: String?
    var matchFilters: String?
    var ageLimit: Int?
    var maxDownloads: Int?
    var noPlaylist: Bool = false
    var playlistRandom: Bool = false
    var breakOnExisting: Bool = false
    
    // MARK: - Livestream
    var liveFromStart: Bool = false
    var waitForVideo: String?
    
    // MARK: - Verbosity
    var verbose: Bool = false
    var quiet: Bool = false
    var simulate: Bool = false
    
    // MARK: - Workarounds
    var userAgent: String?
    var referer: String?
    var customHeaders: [String: String] = [:]
    var sleepInterval: Int?
    var maxSleepInterval: Int?
    var sleepRequests: Double?
    var noCheckCertificates: Bool = false
    var legacyServerConnect: Bool = false
    
    // MARK: - Extractor
    var extractorArgs: [String: String] = [:]
    var useExtractors: String?
    var defaultSearch: String?
    var markWatched: Bool = false
    var flatPlaylist: Bool = false
    var ignoreErrors: Bool = false
    
    func toArgs() -> [String] {
        var args: [String] = []
        
        if let format = format { args.append(contentsOf: ["-f", format]) }
        if let formatSort = formatSort { args.append(contentsOf: ["--format-sort", formatSort]) }
        if formatSortForce { args.append("--format-sort-force") }
        if let mergeOutputFormat = mergeOutputFormat { args.append(contentsOf: ["--merge-output-format", mergeOutputFormat.rawValue]) }
        if let recodeVideo = recodeVideo { args.append(contentsOf: ["--recode-video", recodeVideo]) }
        if let remuxVideo = remuxVideo { args.append(contentsOf: ["--remux-video", remuxVideo]) }
        if preferFreeFormats { args.append("--prefer-free-formats") }
        if checkFormats { args.append("--check-formats") }
        if audioMultistreams { args.append("--audio-multistreams") }
        if videoMultistreams { args.append("--video-multistreams") }
        
        if extractAudio { args.append("--extract-audio") }
        if let audioFormat = audioFormat { args.append(contentsOf: ["--audio-format", audioFormat.rawValue]) }
        args.append(contentsOf: ["--audio-quality", audioBitrate ?? "\(audioQuality)"])
        
        if embedSubs { args.append("--embed-subs") }
        if embedThumbnail { args.append("--embed-thumbnail") }
        if embedMetadata { args.append("--embed-metadata") }
        if embedChapters { args.append("--embed-chapters") }
        if embedInfoJson { args.append("--embed-info-json") }
        if !sponsorblockMark.isEmpty { args.append(contentsOf: ["--sponsorblock-mark", sponsorblockMark.joined(separator: ",")]) }
        if !sponsorblockRemove.isEmpty { args.append(contentsOf: ["--sponsorblock-remove", sponsorblockRemove.joined(separator: ",")]) }
        if let convertSubs = convertSubs { args.append(contentsOf: ["--convert-subs", convertSubs]) }
        if let convertThumbnails = convertThumbnails { args.append(contentsOf: ["--convert-thumbnails", convertThumbnails]) }
        if let fixup = fixup { args.append(contentsOf: ["--fixup", fixup]) }
        if let ffmpegLocation = ffmpegLocation { args.append(contentsOf: ["--ffmpeg-location", ffmpegLocation]) }
        if let postprocessorArgs = postprocessorArgs { args.append(contentsOf: ["--postprocessor-args", postprocessorArgs]) }
        if let execCommand = execCommand { args.append(contentsOf: ["--exec", execCommand]) }
        if splitChapters { args.append("--split-chapters") }
        if let removeChapters = removeChapters { args.append(contentsOf: ["--remove-chapters", removeChapters]) }
        if forceKeyframesAtCuts { args.append("--force-keyframes-at-cuts") }
        if keepVideo { args.append("--keep-video") }
        if noPostOverwrites { args.append("--no-post-overwrites") }
        
        if writeSubs { args.append("--write-subs") }
        if writeAutoSubs { args.append("--write-auto-subs") }
        if let subLangs = subLangs { args.append(contentsOf: ["--sub-langs", subLangs]) }
        if let subFormat = subFormat { args.append(contentsOf: ["--sub-format", subFormat]) }
        
        if let proxy = proxy { args.append(contentsOf: ["--proxy", proxy]) }
        if let socketTimeout = socketTimeout { args.append(contentsOf: ["--socket-timeout", "\(socketTimeout)"]) }
        if let sourceAddress = sourceAddress { args.append(contentsOf: ["--source-address", sourceAddress]) }
        if forceIPv4 { args.append("--force-ipv4") }
        if forceIPv6 { args.append("--force-ipv6") }
        if let impersonate = impersonate { args.append(contentsOf: ["--impersonate", impersonate]) }
        if let geoVerificationProxy = geoVerificationProxy { args.append(contentsOf: ["--geo-verification-proxy", geoVerificationProxy]) }
        if let xff = xff { args.append(contentsOf: ["--xff", xff]) }
        if let username = username { args.append(contentsOf: ["--username", username]) }
        if let password = password { args.append(contentsOf: ["--password", password]) }
        if let twofactor = twofactor { args.append(contentsOf: ["--twofactor", twofactor]) }
        if let videoPassword = videoPassword { args.append(contentsOf: ["--video-password", videoPassword]) }
        if netrc { args.append("--netrc") }
        if let netrcLocation = netrcLocation { args.append(contentsOf: ["--netrc-location", netrcLocation]) }
        if let cookiesFile = cookiesFile { args.append(contentsOf: ["--cookies", cookiesFile]) }
        if let cookiesFromBrowser = cookiesFromBrowser { args.append(contentsOf: ["--cookies-from-browser", cookiesFromBrowser]) }
        
        args.append(contentsOf: ["-o", outputTemplate])
        if let outputNaPlaceholder = outputNaPlaceholder { args.append(contentsOf: ["--output-na-placeholder", outputNaPlaceholder]) }
        if let paths = paths { args.append(contentsOf: ["-P", paths]) }
        if let tempPath = tempPath { args.append(contentsOf: ["--paths", "temp:\(tempPath)"]) }
        if restrictFilenames { args.append("--restrict-filenames") }
        if windowsFilenames { args.append("--windows-filenames") }
        if let trimFilenames = trimFilenames { args.append(contentsOf: ["--trim-filenames", "\(trimFilenames)"]) }
        if noOverwrites { args.append("--no-overwrites") }
        if forceOverwrites { args.append("--force-overwrites") }
        if !continueDownload { args.append("--no-continue") }
        if !usePart { args.append("--no-part") }
        if useMtime { args.append("--mtime") }
        if writeDescription { args.append("--write-description") }
        if writeInfoJson { args.append("--write-info-json") }
        if writeComments { args.append("--write-comments") }
        if cleanInfoJson { args.append("--clean-info-json") }
        else { args.append("--no-clean-info-json") }
        if let downloadArchive = downloadArchive { args.append(contentsOf: ["--download-archive", downloadArchive]) }
        if let batchFile = batchFile { args.append(contentsOf: ["--batch-file", batchFile]) }
        
        if concurrentFragments > 1 { args.append(contentsOf: ["--concurrent-fragments", "\(concurrentFragments)"]) }
        if let limitRate = limitRate { args.append(contentsOf: ["--limit-rate", limitRate]) }
        if let throttledRate = throttledRate { args.append(contentsOf: ["--throttled-rate", throttledRate]) }
        args.append(contentsOf: ["--retries", "\(retries)"])
        args.append(contentsOf: ["--fragment-retries", "\(fragmentRetries)"])
        if let retrySleep = retrySleep { args.append(contentsOf: ["--retry-sleep", retrySleep]) }
        if let bufferSize = bufferSize { args.append(contentsOf: ["--buffer-size", bufferSize]) }
        if let httpChunkSize = httpChunkSize { args.append(contentsOf: ["--http-chunk-size", httpChunkSize]) }
        if let downloader = downloader { args.append(contentsOf: ["--downloader", downloader]) }
        if let downloaderArgs = downloaderArgs { args.append(contentsOf: ["--downloader-args", downloaderArgs]) }
        if hlsUseMpegts { args.append("--hls-use-mpegts") }
        if let downloadSections = downloadSections { args.append(contentsOf: ["--download-sections", downloadSections]) }
        
        if let playlistItems = playlistItems { args.append(contentsOf: ["--playlist-items", playlistItems]) }
        if let minFilesize = minFilesize { args.append(contentsOf: ["--min-filesize", minFilesize]) }
        if let maxFilesize = maxFilesize { args.append(contentsOf: ["--max-filesize", maxFilesize]) }
        if let dateFilter = dateFilter { args.append(contentsOf: ["--date", dateFilter]) }
        if let dateBeforeFilter = dateBeforeFilter { args.append(contentsOf: ["--datebefore", dateBeforeFilter]) }
        if let dateAfterFilter = dateAfterFilter { args.append(contentsOf: ["--dateafter", dateAfterFilter]) }
        if let matchFilters = matchFilters { args.append(contentsOf: ["--match-filter", matchFilters]) }
        if let ageLimit = ageLimit { args.append(contentsOf: ["--age-limit", "\(ageLimit)"]) }
        if let maxDownloads = maxDownloads { args.append(contentsOf: ["--max-downloads", "\(maxDownloads)"]) }
        if noPlaylist { args.append("--no-playlist") }
        if playlistRandom { args.append("--playlist-random") }
        if breakOnExisting { args.append("--break-on-existing") }
        
        if liveFromStart { args.append("--live-from-start") }
        if let waitForVideo = waitForVideo { args.append(contentsOf: ["--wait-for-video", waitForVideo]) }
        
        if verbose { args.append("--verbose") }
        if quiet { args.append("--quiet") }
        if simulate { args.append("--simulate") }
        
        if let userAgent = userAgent { args.append(contentsOf: ["--user-agent", userAgent]) }
        if let referer = referer { args.append(contentsOf: ["--referer", referer]) }
        for (key, value) in customHeaders {
            args.append(contentsOf: ["--add-header", "\(key):\(value)"])
        }
        if let sleepInterval = sleepInterval { args.append(contentsOf: ["--sleep-interval", "\(sleepInterval)"]) }
        if let maxSleepInterval = maxSleepInterval { args.append(contentsOf: ["--max-sleep-interval", "\(maxSleepInterval)"]) }
        if let sleepRequests = sleepRequests { args.append(contentsOf: ["--sleep-requests", "\(sleepRequests)"]) }
        if noCheckCertificates { args.append("--no-check-certificates") }
        if legacyServerConnect { args.append("--legacy-server-connect") }
        
        for (key, value) in extractorArgs {
            args.append(contentsOf: ["--extractor-args", "\(key):\(value)"])
        }
        if let useExtractors = useExtractors { args.append(contentsOf: ["--use-extractors", useExtractors]) }
        if let defaultSearch = defaultSearch { args.append(contentsOf: ["--default-search", defaultSearch]) }
        if markWatched { args.append("--mark-watched") }
        if flatPlaylist { args.append("--flat-playlist") }
        if ignoreErrors { args.append("--ignore-errors") }
        
        return args
    }
}
