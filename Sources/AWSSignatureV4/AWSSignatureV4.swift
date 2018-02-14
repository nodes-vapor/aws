import Core
import Crypto
import HTTP
import Foundation

public enum AccessControlList: String {
    case privateAccess = "private"
    case publicRead = "public-read"
    case publicReadWrite = "public-read-write"
    case awsExecRead = "aws-exec-read"
    case authenticatedRead = "authenticated-read"
    case bucketOwnerRead = "bucket-owner-read"
    case bucketOwnerFullControl = "bucket-owner-full-control"
}

public struct AWSSignatureV4 {
    public enum Method: String {
        case delete = "DELETE"
        case get = "GET"
        case post = "POST"
        case put = "PUT"
    }

    let service: String
    let host: String
    let region: String
    let accessKey: String
    let secretKey: String
    var token: String?
    let contentType = "application/x-www-form-urlencoded; charset=utf-8"

    internal var unitTestDate: Date?

    var amzDate: String {
        let dateFormatter = DateFormatter()
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "YYYYMMdd'T'HHmmss'Z'"
        return dateFormatter.string(from: unitTestDate ?? Date())
    }

    public init(
        service: String,
        host: String,
        region: Region,
        accessKey: String,
        secretKey: String,
        token: String? = nil
    ) {
        self.service = service
        self.host = host
        self.region = region.rawValue
        self.accessKey = accessKey
        self.secretKey = secretKey
        self.token = token
    }

    func getStringToSign(
        algorithm: String,
        date: String,
        scope: String,
        canonicalHash: String
    ) -> String {
        return [
            algorithm,
            date,
            scope,
            canonicalHash
        ].joined(separator: "\n")
    }

    func getSignature(_ stringToSign: String) throws -> String {
        let dateHMAC = try HMAC(.sha256, dateStamp()).authenticate(key: "AWS4\(secretKey)")
        let regionHMAC = try HMAC(.sha256, region).authenticate(key: dateHMAC)
        let serviceHMAC = try HMAC(.sha256, service).authenticate(key: regionHMAC)
        let signingHMAC = try HMAC(.sha256, "aws4_request").authenticate(key: serviceHMAC)

        let signature = try HMAC(.sha256, stringToSign).authenticate(key: signingHMAC)
        return signature.hexString
    }

    func getCredentialScope() -> String {
        return [
            dateStamp(),
            region,
            service,
            "aws4_request"
        ].joined(separator: "/")
    }

    func getCanonicalRequest(
        payloadHash: String,
        method: Method,
        path: String,
        query: String,
        canonicalHeaders: String,
        signedHeaders: String
    ) throws -> String {
        let path = try path.percentEncode(allowing: Byte.awsPathAllowed)
        let query = try query.percentEncode(allowing: Byte.awsQueryAllowed)

        return [
            method.rawValue,
            path,
            query,
            canonicalHeaders,
            "",
            signedHeaders,
            payloadHash
        ].joined(separator: "\n")
    }

    func dateStamp() -> String {
        let date = unitTestDate ?? Date()
        let dateFormatter = DateFormatter()
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateFormat = "YYYYMMdd"
        return dateFormatter.string(from: date)
    }
}

extension AWSSignatureV4 {
    func generateHeadersToSign(
        headers: inout [String: String],
        host: String,
        hash: String
    ) {
        headers["Host"] = host
        headers["X-Amz-Date"] = amzDate

        if let securityToken = token {
            headers["X-Amz-Security-Token"] = securityToken
        }

         if hash != "UNSIGNED-PAYLOAD" {
            headers["x-amz-content-sha256"] = hash
        }
    }

    func alphabetize(_ dict: [String : String]) -> [(key: String, value: String)] {
        return dict.sorted(by: { $0.0.lowercased() < $1.0.lowercased() })
    }

    func createCanonicalHeaders(_ headers: [(key: String, value: String)]) -> String {
        return headers.map {
            "\($0.key.lowercased()):\($0.value)"
        }.joined(separator: "\n")
    }

    func createAuthorizationHeader(
        algorithm: String,
        credentialScope: String,
        signature: String,
        signedHeaders: String
    ) -> String {
        return "\(algorithm) Credential=\(accessKey)/\(credentialScope), SignedHeaders=\(signedHeaders), Signature=\(signature)"
    }
}

extension AWSSignatureV4 {
    /**
    Sign a request to be sent to an AWS API.

    - returns:
    A dictionary with headers to attach to a request

    - parameters:
        - payload: A hash of this data will be included in the headers
        - method: Type of HTTP request
        - path: API call being referenced
        - query: Additional querystring in key-value format ("?key=value&key2=value2")
        - headers: HTTP headers added to the request
    */
    public func sign(
        payload: Payload = .none,
        method: Method = .get,
        path: String,
        query: String? = nil,
        headers: [String : String] = [:]
    ) throws -> [HeaderKey : String] {
        let algorithm = "AWS4-HMAC-SHA256"
        let credentialScope = getCredentialScope()
        let payloadHash = try payload.hashed()

        var headers = headers

        try generateHeadersToSign(headers: &headers, host: host, hash: payloadHash)

        let sortedHeaders = alphabetize(headers)
        let signedHeaders = sortedHeaders.map { $0.key.lowercased() }.joined(separator: ";")
        let canonicalHeaders = createCanonicalHeaders(sortedHeaders)

        // Task 1 is the Canonical Request
        let canonicalRequest = try getCanonicalRequest(
            payloadHash: payloadHash,
            method: method,
            path: path,
            query: query ?? "",
            canonicalHeaders: canonicalHeaders,
            signedHeaders: signedHeaders
        )

        let canonicalHash = try Hash.make(.sha256, canonicalRequest).hexString

        // Task 2 is the String to Sign
        let stringToSign = getStringToSign(
            algorithm: algorithm,
            date: amzDate,
            scope: credentialScope,
            canonicalHash: canonicalHash
        )

        // Task 3 calculates Signature
        let signature = try getSignature(stringToSign)

        //Task 4 Add signing information to the request
        let authorizationHeader = createAuthorizationHeader(
            algorithm: algorithm,
            credentialScope: credentialScope,
            signature: signature,
            signedHeaders: signedHeaders
        )

        var requestHeaders: [HeaderKey: String] = [
            "X-Amz-Date": amzDate,
            "Content-Type": contentType,
            "x-amz-content-sha256": payloadHash,
            "Authorization": authorizationHeader,
            "Host": self.host
        ]

        headers.forEach { key, value in
            let headerKey = HeaderKey(stringLiteral: key)
            requestHeaders[headerKey] = value
        }

        return requestHeaders
    }
}
