import Foundation
import Network

typealias HTTPTransportAdmission = (HTTPRequestHead, HTTPTransport) -> Result<Int, HTTPFailure>

/// Supplied only by the native listener. Names, missing peers and non-IP endpoints fail closed.
struct HTTPTransport {
    let isTLS: Bool
    let peer: NWEndpoint?

    var isLoopback: Bool {
        guard case .hostPort(let host, _) = peer else { return false }
        switch host {
        case .ipv4(let address): return address.rawValue.first == 127
        case .ipv6(let address):
            // A dual-stack socket may report IPv4 peers as IPv4-mapped IPv6.
            return address.isLoopback || (address.isIPv4Mapped && address.asIPv4?.rawValue.first == 127)
        default: return false
        }
    }
}

/// No script, credential input, token reflection or redirect on the cleartext origin.
enum HTTPOnboarding {
    static func page(address: String, httpsPort: UInt16) -> Data {
        // Native addresses can include IPv6 delimiters; never interpolate request-derived data.
        let host = address.contains(":") ? "[\(address)]" : address
        let target = "https://\(host):\(httpsPort)/"
        return Data("""
        <!doctype html><html lang="en"><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta name="referrer" content="no-referrer"><title>PhoneDeck setup</title>
        <h1>Open PhoneDeck securely</h1>
        <p>Controls require HTTPS. Do not enter your access code on this HTTP page.</p>
        <p>First install the <a href="/oldphonedeck.mobileconfig">PhoneDeck certificate profile</a>,
        then enable it in Settings → General → About → Certificate Trust Settings.</p>
        <p><a href="\(target)" rel="noreferrer">Open PhoneDeck over HTTPS</a> and enter your access code there.
        Add the HTTPS page to your Home Screen.</p>
        </html>
        """.utf8)
    }
}
