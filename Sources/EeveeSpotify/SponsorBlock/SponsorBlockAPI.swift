import Foundation

// Talks to the SponsorBlock community API (sponsor.ajay.app).
// Endpoint shape + Spotify "service" identifier follow the convention
// established by Spot-SponsorBlock-Extension:
// https://github.com/Spot-SponsorBlock/Spot-SponsorBlock-Extension

enum SponsorBlockAPIError: Error {
    case badResponse
    case httpStatus(Int)
    case decode
}

enum SponsorBlockAPI {
    static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 8
        c.timeoutIntervalForResource = 10
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    static func fetchSegments(
        episodeID: String,
        options: SponsorBlockOptions,
        completion: @escaping (Result<[SponsorBlockSegment], Error>) -> Void
    ) {
        let cats = options.enabledCategoriesArray()
        guard !cats.isEmpty else { completion(.success([])); return }

        let prefix = SponsorBlockHash.sha256HexPrefix(episodeID, prefixLen: 5)
        guard var components = URLComponents(string: options.serverURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            completion(.failure(SponsorBlockAPIError.badResponse))
            return
        }
        components.path = "/api/skipSegments/\(prefix)"
        let catsJSON: String = {
            let escaped = cats.map { "\"\($0)\"" }.joined(separator: ",")
            return "[\(escaped)]"
        }()
        components.queryItems = [
            URLQueryItem(name: "service", value: "Spotify"),
            URLQueryItem(name: "categories", value: catsJSON),
        ]
        guard let url = components.url else {
            completion(.failure(SponsorBlockAPIError.badResponse))
            return
        }

        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("EeveeSpotify-SponsorBlock/1", forHTTPHeaderField: "X-CLIENT-NAME")

        session.dataTask(with: req) { data, resp, err in
            if let err { completion(.failure(err)); return }
            guard let http = resp as? HTTPURLResponse else {
                completion(.failure(SponsorBlockAPIError.badResponse)); return
            }
            if http.statusCode == 404 {
                completion(.success([])); return
            }
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure(SponsorBlockAPIError.httpStatus(http.statusCode))); return
            }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                completion(.failure(SponsorBlockAPIError.decode)); return
            }
            let segments = parse(videoID: episodeID, json: json)
            completion(.success(segments))
        }.resume()
    }

    private static func parse(videoID: String, json: [[String: Any]]) -> [SponsorBlockSegment] {
        var out: [SponsorBlockSegment] = []
        for obj in json {
            guard let vid = obj["videoID"] as? String, vid == videoID,
                  let segs = obj["segments"] as? [[String: Any]] else { continue }
            for s in segs {
                guard let pair = s["segment"] as? [Double], pair.count == 2,
                      let cat = s["category"] as? String,
                      let action = s["actionType"] as? String,
                      let uuid = s["UUID"] as? String else { continue }
                let dur = s["videoDuration"] as? Double ?? 0
                out.append(SponsorBlockSegment(
                    start: pair[0],
                    end: pair[1],
                    category: cat,
                    actionType: action,
                    uuid: uuid,
                    videoDuration: dur
                ))
            }
        }
        return out.sorted { $0.start < $1.start }
    }
}
