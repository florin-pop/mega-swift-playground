import Foundation
import PlaygroundSupport
import CryptoSwift
import CoreImage


typealias JSONObject = [String: Any]
typealias JSONArray = [JSONObject]

enum DownloadError: Error {
    case badURL, requestFailed, badResponse, unknown
}

extension String {
    func base64Decoded() -> Data? {
        let padded = self.replacingOccurrences(of: ",", with: "")
            .padding(toLength: ((self.count + 3) / 4) * 4,
                     withPad: "=",
                     startingAt: 0)
        let sanitized = padded.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        return Data(base64Encoded: sanitized)
    }
}


extension Data {
    init(uInt32Array: [UInt32]) {
        self.init(capacity: uInt32Array.count * 4)
        for val in uInt32Array {
            Swift.withUnsafeBytes(of: val.bigEndian) { self.append(contentsOf: $0) }
        }
    }
    
    func toUInt32Array() -> [UInt32] {
        var result = [UInt32]()
        let dataChunks = self.chunked(into: 4)
        
        for i in 0..<dataChunks.count {
            // https://stackoverflow.com/a/56854262
            let bigEndianUInt32 = dataChunks[i].withUnsafeBytes { $0.load(as: UInt32.self) }
            let value = CFByteOrderGetCurrent() == CFByteOrder(CFByteOrderLittleEndian.rawValue)
                ? UInt32(bigEndian: bigEndianUInt32)
                : bigEndianUInt32
            result.append(value)
        }
        
        return result
    }
    
    // https://www.hackingwithswift.com/example-code/language/how-to-split-an-array-into-chunks
    func chunked(into size: Int) -> [[Element]] {
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0 ..< Swift.min($0 + size, count)])
        }
    }
}

struct MegaLink {
    
    // http://megous.com/git/megatools/tree/tools/dl.c#n363
    private static let regexes: [String] = [
        "^https?://mega(?:\\.co)?\\.nz/#!([a-z0-9_-]{8})!([a-z0-9_-]{43})$",
        "^https?://mega\\.nz/file/([a-z0-9_-]{8})#([a-z0-9_-]{43})$"
    ]
    
    let url: String
    let id: String
    let key: String
    
    init?(url: String) {
        self.url = url
        let matchResult: NSTextCheckingResult? = {
            for pattern in Self.regexes {
                let range = NSRange(url.startIndex..<url.endIndex, in: url)
                let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
                
                if let match = regex?.matches(in: url, range: range).first,
                   match.numberOfRanges >= 2 {
                    return match
                }
            }
            return nil
        }()
        
        guard let match = matchResult else { return nil }
        
        let string = url as NSString
        self.id = string.substring(with: match.range(at: 1))
        self.key = string.substring(with: match.range(at: 2)).replacingOccurrences(of: "%20", with: "")
    }
}

extension MegaLink {
    var ctrCipher: Cipher? {
        guard let base64Key = self.key.base64Decoded() else {
            return nil
        }
        
        let intKey = base64Key.toUInt32Array()
        let keyNOnce = [intKey[0] ^ intKey[4], intKey[1] ^ intKey[5], intKey[2] ^ intKey[6], intKey[3] ^ intKey[7], intKey[4], intKey[5]]
        let key = Data(uInt32Array: [keyNOnce[0], keyNOnce[1], keyNOnce[2], keyNOnce[3]])
        let iiv = [keyNOnce[4], keyNOnce[5], 0, 0]
        let iv = Data(uInt32Array: iiv)
        
        return try? AES(key: Array(key), blockMode: CTR(iv: Array(iv)), padding: .noPadding)
    }
    
    var cbcCipher: Cipher? {
        guard let base64Key = self.key.base64Decoded() else {
            return nil
        }
        
        let intKey = base64Key.toUInt32Array()
        let key = Data(uInt32Array: [intKey[0] ^ intKey[4], intKey[1] ^ intKey[5], intKey[2] ^ intKey[6], intKey[3] ^ intKey[7]])
        let iiv: [UInt32] = [0, 0, 0, 0]
        let iv = Data(uInt32Array: iiv)
        
        return try? AES(key: Array(key), blockMode: CBC(iv: Array(iv)), padding: .zeroPadding)
    }
}

struct MegaFileInfo: Decodable {
    struct Attributes: Decodable {
        let name: String
        
        enum CodingKeys: String, CodingKey {
            case name = "n"
        }
    }
    
    let size: Int64
    let encryptedAttributes: String
    let downloadLink: String
    
    enum CodingKeys: String, CodingKey {
        case size = "s"
        case encryptedAttributes = "at"
        case downloadLink = "g"
    }
}

extension MegaFileInfo {
    func decryptAttributes(using cipher: Cipher) -> Attributes? {
        guard let attributeData = try? encryptedAttributes.base64Decoded()?.decrypt(cipher: cipher),
              let attributeString = String(data: attributeData, encoding: .utf8),
              attributeString.starts(with: "MEGA{"),
              let attributeJSONData = attributeString[attributeString.index( attributeString.startIndex, offsetBy: 4)...].data(using: .utf8),
              let attributes = try? JSONDecoder().decode(Attributes.self, from: attributeJSONData)
        else {
            return nil
        }
        return attributes
    }
}

func getDownloadLink(from link: MegaLink, completion: @escaping (Result<String, DownloadError>) -> Void) {
    var urlComponents = URLComponents(string: "https://g.api.mega.co.nz/cs")
    
    urlComponents?.queryItems = [
        URLQueryItem(name: "id", value: "1"), // random int
    ]
    
    guard let url = urlComponents?.url else {
        completion(.failure(.badURL))
        return
    }
    
    let requestPayload = [[
        "a": "g", // action
        "g": "1",
        "ssl": "1",
        "p": megaLink.id
    ]]
    
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    
    guard let requestData = try? JSONSerialization.data(withJSONObject: requestPayload, options: []) else {
        completion(.failure(.requestFailed))
        return
    }
    
    request.httpBody = requestData
    
    URLSession.shared.dataTask(with: request) { data, response, error in
        DispatchQueue.main.async {
            if let data = data {
                if let response = try? JSONDecoder().decode([MegaFileInfo].self, from: data),
                   let fileInfo = response.first,
                   let cipher = megaLink.cbcCipher,
                   let fileName = fileInfo.decryptAttributes(using: cipher)?.name {
                    print(fileName)
                    completion(.success(fileInfo.downloadLink))
                } else {
                    completion(.failure(.badResponse))
                }
            } else if error != nil {
                completion(.failure(.requestFailed))
            } else {
                completion(.failure(.unknown))
            }
        }
    }.resume()
}

func download(from link: MegaLink, completion: @escaping (Result<Data, DownloadError>) -> Void) {
    getDownloadLink(from: megaLink) { result in
        switch result {
        case .success(let downloadLink):
            guard let url = URL(string: downloadLink) else {
                completion(.failure(.badURL))
                return
            }
            
            URLSession.shared.dataTask(with: url) { data, response, error in
                DispatchQueue.main.async {
                    if let data = data {
                        completion(.success(data))
                    } else if error != nil {
                        completion(.failure(.requestFailed))
                    } else {
                        completion(.failure(.unknown))
                    }
                }
            }.resume()
            
        case .failure(let error):
            completion(.failure(error))
        }
    }
}

let megaLink = MegaLink(url: "https://mega.nz/file/nyIECKrQ#c3tzkRH1OtQ-cxvOc26B9TkwXy9MNdRpciaOjq-0B6o")!

download(from: megaLink) { result in
    switch result {
    case .success(let encryptedData):
        if let cipher = megaLink.ctrCipher,
           let data = try? encryptedData.decrypt(cipher: cipher) {
            CIImage(data: data)
        } else {
            print("Decryption failed")
        }
    case .failure(let error):
        print("Download failed")
        print(error)
    }
}

