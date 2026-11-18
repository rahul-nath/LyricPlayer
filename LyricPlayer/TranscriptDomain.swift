import Foundation
import OSLog

enum PlaybackTiming {
    static let globalOffsetSeconds: TimeInterval = 0
}

struct NormalizedTrackTitle: Hashable, CustomStringConvertible {
    let value: String

    init?(_ title: String) {
        let withoutPunctuation = title.lowercased().unicodeScalars.filter {
            !CharacterSet.punctuationCharacters.contains($0)
        }
        let normalized = String(String.UnicodeScalarView(withoutPunctuation))
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")

        guard !normalized.isEmpty else { return nil }
        value = normalized
    }

    var description: String { value }
}

struct LyricLine: Equatable {
    let timestampSeconds: TimeInterval
    let text: String
}

struct LyricTranscript {
    let title: NormalizedTrackTitle
    let lines: [LyricLine]

    static func parse(contents: String, title: NormalizedTrackTitle) -> LyricTranscript {
        let parsedLines = contents
            .split(whereSeparator: \Character.isNewline)
            .enumerated()
            .compactMap { offset, rawLine -> (offset: Int, line: LyricLine)? in
                guard let line = parseLine(String(rawLine)) else { return nil }
                return (offset, line)
            }
            .sorted {
                if $0.line.timestampSeconds == $1.line.timestampSeconds {
                    return $0.offset < $1.offset
                }
                return $0.line.timestampSeconds < $1.line.timestampSeconds
            }
            .map(\.line)

        return LyricTranscript(title: title, lines: parsedLines)
    }

    func activeLineIndex(at playbackTime: TimeInterval) -> Int? {
        guard playbackTime.isFinite, !lines.isEmpty else { return nil }

        var lowerBound = 0
        var upperBound = lines.count

        while lowerBound < upperBound {
            let middle = lowerBound + (upperBound - lowerBound) / 2
            if lines[middle].timestampSeconds <= playbackTime {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }

        return lowerBound == 0 ? nil : lowerBound - 1
    }

    private static func parseLine(_ rawLine: String) -> LyricLine? {
        guard rawLine.first == "[", let closingBracket = rawLine.firstIndex(of: "]") else {
            return nil
        }

        let timestampStart = rawLine.index(after: rawLine.startIndex)
        let timestamp = rawLine[timestampStart..<closingBracket]
        let components = timestamp.split(separator: ":", omittingEmptySubsequences: false)
        let secondComponents = components.count == 2
            ? components[1].split(separator: ".", omittingEmptySubsequences: false)
            : []
        guard components.count == 2,
              components[0].count >= 2, components[0].allSatisfy(\.isWholeNumber),
              secondComponents.count == 2,
              secondComponents[0].count == 2, secondComponents[0].allSatisfy(\.isWholeNumber),
              secondComponents[1].count == 2, secondComponents[1].allSatisfy(\.isWholeNumber),
              let minutes = Int(components[0]), minutes >= 0,
              let seconds = Double(components[1]), seconds >= 0, seconds < 60 else {
            return nil
        }

        let textStart = rawLine.index(after: closingBracket)
        let text = rawLine[textStart...].trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        return LyricLine(timestampSeconds: TimeInterval(minutes) * 60 + seconds, text: text)
    }
}

enum TranscriptResolution {
    case matched(LyricTranscript)
    case missing(NormalizedTrackTitle?)
    case ambiguous(NormalizedTrackTitle)
    case unreadable(NormalizedTrackTitle)
}

struct TranscriptCatalog {
    private let resourceDirectoriesByIncreasingPrecedence: [URL]
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "com.rahul.LyricPlayer", category: "TranscriptBinding")

    init(resourceDirectories: [URL], fileManager: FileManager = .default) {
        resourceDirectoriesByIncreasingPrecedence = resourceDirectories
        self.fileManager = fileManager
    }

    static func live(bundle: Bundle = .main, fileManager: FileManager = .default) -> TranscriptCatalog {
        var directories: [URL] = []
        if let resourceURL = bundle.resourceURL {
            directories.append(resourceURL)
        }
        if let documentsURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            directories.append(documentsURL)
        }
        return TranscriptCatalog(resourceDirectories: directories, fileManager: fileManager)
    }

    func resolve(trackTitle: String) -> TranscriptResolution {
        guard let normalizedTitle = NormalizedTrackTitle(trackTitle) else {
            logger.info("transcript lookup key=<empty> result=miss")
            return .missing(nil)
        }

        let candidates = candidateURLs(for: normalizedTitle)
        guard candidates.count == 1 else {
            if candidates.isEmpty {
                logger.info("transcript lookup key=\(normalizedTitle.value, privacy: .private) result=miss")
                return .missing(normalizedTitle)
            }
            logger.error("transcript lookup key=\(normalizedTitle.value, privacy: .private) result=ambiguous count=\(candidates.count)")
            return .ambiguous(normalizedTitle)
        }

        do {
            let contents = try String(contentsOf: candidates[0], encoding: .utf8)
            let transcript = LyricTranscript.parse(contents: contents, title: normalizedTitle)
            guard !transcript.lines.isEmpty else {
                logger.error("transcript lookup key=\(normalizedTitle.value, privacy: .private) result=unreadable")
                return .unreadable(normalizedTitle)
            }
            logger.info("transcript lookup key=\(normalizedTitle.value, privacy: .private) result=hit")
            return .matched(transcript)
        } catch {
            logger.error("transcript lookup key=\(normalizedTitle.value, privacy: .private) result=unreadable")
            return .unreadable(normalizedTitle)
        }
    }

    private func candidateURLs(for title: NormalizedTrackTitle) -> [URL] {
        for directory in resourceDirectoriesByIncreasingPrecedence.reversed() {
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }

            let urls = contents.filter { url in
                url.pathExtension.lowercased() == "lrc"
                    && NormalizedTrackTitle(url.deletingPathExtension().lastPathComponent) == title
            }
            let uniqueURLs = Array(Set(urls.map(\.standardizedFileURL)))
            if !uniqueURLs.isEmpty {
                return uniqueURLs
            }
        }
        return []
    }
}
