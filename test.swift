#!/usr/bin/swift sh

import Foundation
import SwiftCSV // hamchapman/SwiftCSV2 == swiftpm
import PromiseKit  // @mxcl ~> 6.7
import PMKFoundation // PromiseKit/Foundation ~> 3.3
import SwiftSoup // @scinfu ~> 1.7

let runLoop = RunLoop.current
var opCount = 1

opCount += 1

struct ShowRating {
    let id: String
    let rating: Double
}

struct ShowBasics {
    let id: String
    let title: String
}

struct Show {
    let id: String
    let rating: Double
    let title: String
}

let fileManager = FileManager.default
let downloadsDirs = fileManager.urls(
    for: .downloadsDirectory,
    in: .userDomainMask
)

guard let downloadsDir = downloadsDirs.first else {
    fatalError("Couldn't get downloads directory")
}

print("Using downloads directory: \(downloadsDir)")

func urlRequestFor(showID: String, season: Int) -> URLRequest {
    let url = URL(string: "https://www.imdb.com/title/\(showID)/episodes?season=\(season)")!
    var rq = URLRequest(url: url)
    rq.httpMethod = "GET"
    return rq
}

func getRatingsForShow(
    id: String,
    season: Int = 1,
    ratingsResults: [String: [Double]] = [String: [Double]]()
) -> Promise<[String: [Double]]> {
    return getRatingsFor(showID: id, season: season)
        .then { (seasonRatings: SeasonRatings) -> Promise<[String: [Double]]> in
            var ratingsBySeason = ratingsResults
            ratingsBySeason["\(season)"] = seasonRatings.ratings
            if seasonRatings.nextSeasonExists {
                return getRatingsForShow(
                    id: id,
                    season: season + 1,
                    ratingsResults: ratingsBySeason
                )
            } else {
                return Promise.value(ratingsBySeason)
            }
        }
}

func getRatingsFor(showID: String, season: Int) -> Promise<SeasonRatings> {
    let req = urlRequestFor(showID: showID, season: season)
    return firstly {
        URLSession.shared.dataTask(.promise, with: req).validate()
    }.map {
        String(decoding: $0.data, as: UTF8.self)
    }.map { html -> SeasonRatings in
        print("GOT HTML")
        guard let doc = try? SwiftSoup.parse(html) else {
            fatalError("Couldn't get document from html")
        }

        guard let voteCountElems = try? doc.getElementsByClass("ipl-rating-star__total-votes") else {
            fatalError("Couldn't get vote count elements from html")
        }

        var ratings = [Double]()

        for voteCountElem: Element in voteCountElems.array() {
            let rating = try! voteCountElem.previousElementSibling()!.text()
            ratings.append(Double(rating)!)
        }

        let nextSeasonLink = try doc.getElementById("load_next_episodes")?.attr("href")
        let nextSeasonExists = nextSeasonLink != nil

        return SeasonRatings(
            ratings: ratings,
            nextSeasonExists: nextSeasonExists
        )
    }
}

struct SeasonRatings {
    let ratings: [Double]
    let nextSeasonExists: Bool
}

class StreamReader  {
    let encoding : String.Encoding
    let chunkSize : Int
    var fileHandle : FileHandle!
    let delimData : Data
    var buffer : Data
    var atEof : Bool

    init?(
        path: String,
        delimiter: String = "\n",
        encoding: String.Encoding = .utf8,
        chunkSize: Int = 4096
    ) {
        guard
            let fileHandle = FileHandle(forReadingAtPath: path),
            let delimData = delimiter.data(using: encoding)
        else {
            return nil
        }
        self.encoding = encoding
        self.chunkSize = chunkSize
        self.fileHandle = fileHandle
        self.delimData = delimData
        self.buffer = Data(capacity: chunkSize)
        self.atEof = false
    }

    deinit {
        self.close()
    }

    /// Return next line, or nil on EOF.
    func nextLine() -> String? {
        precondition(fileHandle != nil, "Attempt to read from closed file")

        // Read data chunks from file until a line delimiter is found:
        while !atEof {
            if let range = buffer.range(of: delimData) {
                // Convert complete line (excluding the delimiter) to a string:
                let line = String(
                    data: buffer.subdata(in: 0..<range.lowerBound),
                    encoding: encoding
                )
                // Remove line (and the delimiter) from the buffer:
                buffer.removeSubrange(0..<range.upperBound)
                return line
            }
            let tmpData = fileHandle.readData(ofLength: chunkSize)
            if tmpData.count > 0 {
                buffer.append(tmpData)
            } else {
                // EOF or read error.
                atEof = true
                if buffer.count > 0 {
                    // Buffer contains last line in file (not terminated by
                    // delimiter).
                    let line = String(data: buffer as Data, encoding: encoding)
                    buffer.count = 0
                    return line
                }
            }
        }
        return nil
    }

    /// Start reading from the beginning of file.
    func rewind() -> Void {
        fileHandle.seek(toFileOffset: 0)
        buffer.count = 0
        atEof = false
    }

    /// Close the underlying file. No reading must be done after calling this
    // method.
    func close() -> Void {
        fileHandle?.closeFile()
        fileHandle = nil
    }
}

extension StreamReader: Sequence {
    func makeIterator() -> AnyIterator<String> {
        return AnyIterator {
            return self.nextLine()
        }
    }
}

let ratingsFile = downloadsDir.appendingPathComponent("title.ratings.tsv")
let basicsFile = downloadsDir.appendingPathComponent("title.basics.tsv")

let rs = StreamReader(path: ratingsFile.path, delimiter: "\n")
let bs = StreamReader(path: basicsFile.path, delimiter: "\n")

guard let ratingsStreamer = rs else {
    fatalError("Unable to read ratings file")
}

let ratingsHeader = ratingsStreamer.nextLine() // ignore first line (header)
print(ratingsHeader!)

var lotsOfVotes = [String: ShowRating]()

for line in ratingsStreamer {
    let splitLine = line.split(separator: "\t")
    let numVotes = Int(splitLine[2])!
    if numVotes > 100_000 {
        // TODO
        let showID = String(splitLine[0])
        let showRating = ShowRating(
            id: showID,
            rating: Double(splitLine[1])!
        )
        lotsOfVotes[showID] = showRating
    }
}

// print(lotsOfVotes)
print(lotsOfVotes.count)

getRatingsForShow(id: "tt0411008")
    .done { seasonRatings in
        print(seasonRatings)

        let seasonCount: Int = seasonRatings.count
        var seasonAveragedRating: Double = 0

        seasonRatings.values.forEach { ratings in
            seasonAveragedRating += ratings.reduce(0, +) / Double(ratings.count)
        }

        let overallSeasonBasedAverage = seasonAveragedRating / Double(seasonCount)
        print("Season-based average: \(overallSeasonBasedAverage)")

        var episodeCount: Int = 0
        var episodeAveragedRating: Double = 0

        seasonRatings.values.forEach { seasonRatings in
            seasonRatings.forEach { episodeRating in
                episodeCount += 1
                episodeAveragedRating += episodeRating
            }
        }

        let overallRating = episodeAveragedRating / Double(episodeCount)
        print("Episodic average: \(overallRating)")

        opCount -= 1
    }.catch { error in
        print("Error getting season ratings for show: \(error.localizedDescription)")
    }

// MARK: Now on to the basics file

// guard let basicsStreamer = bs else {
//     fatalError("Unable to read basics file")
// }

// let basicssHeader = basicsStreamer.nextLine() // ignore first line (header)
// print(basicssHeader!)

// var tvSeries = [String: ShowBasics]()

// for line in basicsStreamer {
//     let splitLine = line.split(separator: "\t")

//     let titleType = splitLine[1]
//     if titleType == "tvSeries" {
//         let showID = String(splitLine[0])
//         let showBasics = ShowBasics(
//             id: showID,
//             title: String(splitLine[2])
//         )
//         tvSeries[showID] = showBasics
//     }
// }

// var lotsOfVoteTVShows = [Show]()

// lotsOfVotes.keys.forEach { showID in
//     guard let showBasics = tvSeries[showID] else {
//         return
//     }
//     let show = Show(
//         id: showID,
//         rating: lotsOfVotes[showID]!.rating,
//         title: showBasics.title
//     )
//     lotsOfVoteTVShows.append(show)
// }

// print(lotsOfVoteTVShows)

opCount -= 1


while
    opCount > 0 &&
    runLoop.run(
        mode: .default,
        before: Date(timeIntervalSinceNow: 0.1)
    )
{
    // Run until done
}
