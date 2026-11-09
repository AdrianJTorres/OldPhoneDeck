import Foundation
import Testing
@testable import oldphonedeck

final class HTTPParsingTests {
    private let token = "test-only-token"

    private func parse(_ wire: String) throws -> HTTPRequest? {
        var parser = HTTPRequestParser()
        return try parser.receive(Data(wire.utf8)) { DeckRoute.admit($0, token: token) }
    }

    private func status(_ wire: String, _ expected: Int, sourceLocation: SourceLocation = #_sourceLocation) {
        do {
            _ = try parse(wire)
            Issue.record("Expected request rejection", sourceLocation: sourceLocation)
        } catch {
            #expect((error as? HTTPFailure)?.status == expected, sourceLocation: sourceLocation)
        }
    }

    private func post(_ path: String = "/media", length: String? = "0", extra: String = "", body: String = "") -> String {
        "POST \(path)?k=\(token) HTTP/1.1\r\n" + (length.map { "Content-Length: \($0)\r\n" } ?? "") + extra + "\r\n" + body
    }

    @Test func testNormalRequest() throws {
        let request = try #require(try parse("GET /stats?k=\(token) HTTP/1.1\r\nHost: localhost\r\n\r\n"))
        #expect(request.method == "GET")
        #expect(request.path == "/stats")
        #expect(request.headers["host"] == "localhost")
        #expect(request.body.isEmpty)
    }

    @Test func testFragmentedHeadersAndBody() throws {
        var parser = HTTPRequestParser()
        var requests: [HTTPRequest] = []
        var admissions = 0
        for byte in post(length: "3", body: "abc").utf8 {
            if let request = try parser.receive(Data([byte]), admission: { head in
                admissions += 1
                return DeckRoute.admit(head, token: self.token)
            }) { requests.append(request) }
        }
        #expect(admissions == 1)
        #expect(requests.count == 1)
        #expect(requests.first?.body == Data("abc".utf8))
        #expect(parser.phase == .complete)
    }

    @Test func testRequestLineBoundary() throws {
        // GET + SP + target + SP + HTTP/1.1 = exactly 4096 bytes, excluding CRLF.
        let target = "/" + String(repeating: "a", count: 4096 - 14)
        let wire = "GET \(target) HTTP/1.1\r\n\r\n"
        status(wire, 404) // Framing accepted; route is intentionally unknown.
        status("GET \(target)a HTTP/1.1\r\n\r\n", 414)
    }

    @Test func testTotalHeaderBoundary() throws {
        let base = "GET / HTTP/1.1\r\n"
        let field = "X: " + String(repeating: "a", count: 4093) + "\r\n"
        let prefix = base + field + field + field
        let lastValue = 16384 - prefix.utf8.count - "Y: \r\n\r\n".utf8.count
        let wire = prefix + "Y: " + String(repeating: "b", count: lastValue) + "\r\n\r\n"
        #expect(wire.utf8.count == 16384)
        #expect(try parse(wire) != nil)
        status(prefix + "Y: " + String(repeating: "b", count: lastValue + 1) + "\r\n\r\n", 431)
    }

    @Test func testHeaderFieldCountBoundary() throws {
        let prefix = "GET / HTTP/1.1\r\n" + String(repeating: "X: a\r\n", count: 64)
        #expect(try parse(prefix + "\r\n") != nil)
        status(prefix + "Y: b\r\n\r\n", 431)
    }

    @Test func testIndividualHeaderBoundary() throws {
        #expect(try parse("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 4093) + "\r\n\r\n") != nil)
        status("GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 4094) + "\r\n\r\n", 431)
    }

    @Test func testMalformedRequestLinesAndTargets() {
        for line in ["GET", "GET /", "GET  / HTTP/1.1", "GET / HTTP/2", "GET / HTTP/1.1 extra",
                     "GE\tT / HTTP/1.1", "GET http://example.com/ HTTP/1.1", "GET //example.com/ HTTP/1.1",
                     "GET /#fragment HTTP/1.1", "GET /%zz HTTP/1.1", "GET /% HTTP/1.1"] {
            status(line + "\r\n\r\n", 400)
        }
    }

    @Test func testMalformedHeaderSyntax() {
        for header in ["MissingColon", " Bad: folded", ": empty", "Name : value", "X: a\u{00}b"] {
            status("GET / HTTP/1.1\r\n" + header + "\r\n\r\n", 400)
        }
        status("GET / HTTP/1.1\n\n", 400)
        status("GET / HTTP/1.1\rX", 400)
    }

    @Test func testZeroAndPositiveContentLength() throws {
        #expect(try parse(post(length: "0"))?.body.count == 0)
        #expect(try parse(post(length: "3", body: "abc"))?.body == Data("abc".utf8))
        #expect(try parse(post(length: "0003", body: "abc"))?.body.count == 3)
    }

    @Test func testInvalidContentLengths() {
        for length in ["-1", "+1", "1a", "1.0", "", "1, 1", "1 0", "9999999999999999999999999999"] {
            status(post(length: length), 400)
        }
    }

    @Test func testDuplicateContentLengthRejectedCaseInsensitively() {
        status(post(extra: "content-LENGTH: 0\r\n"), 400)
        status(post(extra: "Content-Length: 1\r\n"), 400)
    }

    @Test func testContentLengthExceedsRouteLimit() {
        status(post(length: "1025"), 413)
        status(post("/launch", length: "16385"), 413)
        status(post("/claude", length: "65537"), 413)
        status(post("/launcher", length: "65537"), 413)
    }

    @Test func testTransferEncodingAndExpectRejected() {
        for value in ["chunked", "identity", ""] {
            status(post(extra: "Transfer-Encoding: \(value)\r\n"), 400)
        }
        status(post(extra: "Expect: 100-continue\r\n"), 417)
        status(post(extra: "Expect: \r\n"), 417)
    }

    @Test func testRequiredContentLength() {
        for path in ["/media", "/launch", "/claude", "/launcher"] {
            status(post(path, length: nil), 411)
        }
    }

    @Test func testBodylessRoutes() throws {
        #expect(try parse(post("/speedtest", length: nil)) != nil)
        #expect(try parse(post("/speedtest")) != nil)
        status(post("/speedtest", length: "1"), 413)
        status("GET /stats?k=\(token) HTTP/1.1\r\nContent-Length: 1\r\n\r\n", 413)
        status("GET / HTTP/1.1\r\nContent-Length: 1\r\n\r\n", 413)
    }

    @Test func testIncompleteBodyCannotProduceRequest() throws {
        var parser = HTTPRequestParser()
        let admission: HTTPAdmission = { DeckRoute.admit($0, token: self.token) }
        #expect(try parser.receive(Data(post(length: "3", body: "a").utf8), admission: admission) == nil)
        #expect(parser.phase == .body)
        #expect(parser.bufferedBodyBytes == 1)
        #expect(parser.maximumReceiveLength == 2)
        #expect(try parser.receive(Data("b".utf8), admission: admission) == nil)
        #expect(try parser.receive(Data("c".utf8), admission: admission) != nil)
        #expect(try parser.receive(Data("GET / HTTP/1.1\r\n\r\n".utf8), admission: admission) == nil)
    }

    @Test func testOverLimitDeclarationRetainsNoBody() {
        var parser = HTTPRequestParser()
        do {
            _ = try parser.receive(Data(post(length: "1025", body: String(repeating: "a", count: 1025)).utf8),
                                   admission: { DeckRoute.admit($0, token: self.token) })
            Issue.record("Expected oversized declaration rejection")
        } catch { #expect((error as? HTTPFailure)?.status == 413) }
        #expect(parser.bufferedBodyBytes == 0)
        #expect(parser.phase == .failed)
        #expect(parser.maximumReceiveLength == 0)
    }

    @Test func testBytesBeyondDeclaredLengthRejected() {
        status(post(length: "1", body: "ab"), 400)
        status("GET / HTTP/1.1\r\n\r\nGET / HTTP/1.1\r\n\r\n", 400)
    }

    @Test func testPublicRoutesNeedNoToken() throws {
        for path in ["/", "/index.html", "/oldphonedeck.mobileconfig"] {
            #expect(try parse("GET \(path) HTTP/1.1\r\n\r\n") != nil)
            status("POST \(path) HTTP/1.1\r\nContent-Length: 0\r\n\r\n", 405)
        }
    }

    @Test func testMissingAndWrongTokenRejectedBeforeBodyCollection() {
        for query in ["", "?k=wrong", "?text=hello"] {
            var parser = HTTPRequestParser()
            let wire = "POST /claude\(query) HTTP/1.1\r\nContent-Length: 536870912\r\n\r\n" + String(repeating: "a", count: 4096)
            do {
                _ = try parser.receive(Data(wire.utf8), admission: { DeckRoute.admit($0, token: self.token) })
                Issue.record("Expected authentication rejection")
            } catch { #expect((error as? HTTPFailure)?.status == 403) }
            #expect(parser.bufferedBodyBytes == 0)
        }
    }

    @Test func testBodyTokenDoesNotAuthenticate() {
        status("POST /media HTTP/1.1\r\nContent-Length: 17\r\n\r\nk=\(token)", 403)
    }

    @Test func testDuplicateQueryTokensRejected() {
        for query in ["k=\(token)&k=\(token)", "k=wrong&%6b=\(token)", "k&k=\(token)"] {
            status("GET /stats?\(query) HTTP/1.1\r\n\r\n", 400)
        }
    }

    @Test func testUnknownAndUnimplementedRoutesFailClosed() {
        status("GET /missing HTTP/1.1\r\n\r\n", 404)
        status(post("/action", length: "65536"), 404)
        status("DELETE /stats?k=\(token) HTTP/1.1\r\n\r\n", 405)
    }

    @Test func testEveryDeclaredRouteHasExpectedBodyLimit() throws {
        let expected: [String: Int] = ["/shortcut": 1024, "/media": 1024, "/launch": 16384, "/claude": 65536, "/launcher": 65536]
        for route in DeckRoute.allCases {
            let head = HTTPRequestHead(method: route.method, path: route.path, query: ["k": token], headers: [:], contentLength: 0)
            let limit = route.method == "POST" ? expected[route.path] ?? 0 : 0
            #expect(try DeckRoute.admit(head, token: token).get() == limit)
        }
    }

    @Test func testMaximumBodyCanBeCollectedInBoundedReads() throws {
        var parser = HTTPRequestParser()
        let admission: HTTPAdmission = { DeckRoute.admit($0, token: self.token) }
        #expect(try parser.receive(Data(post("/launcher", length: "65536").utf8), admission: admission) == nil)
        for i in 0..<4 {
            #expect(parser.maximumReceiveLength == 16384)
            let request = try parser.receive(Data(repeating: 97, count: 16384), admission: admission)
            if i < 3 { #expect(request == nil) } else { #expect(request?.body.count == 65536) }
        }
    }

    @Test func testHeaderReadAllowanceIsBounded() throws {
        var parser = HTTPRequestParser()
        #expect(parser.maximumReceiveLength == 4096)
        let wire = "GET / HTTP/1.1\r\n" + String(repeating: "X: " + String(repeating: "a", count: 4093) + "\r\n", count: 3)
        #expect(try parser.receive(Data(wire.utf8), admission: { _ in .success(0) }) == nil)
        #expect(parser.maximumReceiveLength == 16384 - wire.utf8.count)
    }

    @Test func testDecodedParameterLimits() throws {
        func request(_ path: String, _ body: String) -> HTTPRequest {
            HTTPRequest(method: "POST", path: path, query: [:],
                        headers: ["content-type": "application/x-www-form-urlencoded"], body: Data(body.utf8))
        }
        #expect(DeckRoute.validateParameters(request("/launch", "path=" + String(repeating: "a", count: 4096))) == nil)
        #expect(DeckRoute.validateParameters(request("/launch", "path=" + String(repeating: "%C3%A9", count: 2049)))?.status == 413)
        #expect(DeckRoute.validateParameters(request("/claude", "text=" + String(repeating: "a", count: 16384))) == nil)
        #expect(DeckRoute.validateParameters(request("/claude", "text=" + String(repeating: "a", count: 16385)))?.status == 413)
        for send in ["0", "1"] { #expect(DeckRoute.validateParameters(request("/claude", "send=" + send)) == nil) }
        #expect(DeckRoute.validateParameters(request("/claude", "send=yes"))?.status == 400)
        #expect(DeckRoute.validateParameters(request("/claude", "send="))?.status == 400)
    }
}
