import CryptoKit
import Foundation
import WebRTC

/// Builds the ICE server list for WebRTC from `AppConfig`: public STUN plus, when
/// a coturn host + static-auth-secret are configured, time-limited TURN
/// credentials (coturn `use-auth-secret` / TURN REST). TURN relay is essential
/// for thin or symmetric-NAT field networks where STUN alone won't connect.
enum WebRTCConfig {

    static var maxBitrateBps: Int { AppConfig.shared.maxVideoBitrateBps }
    static let maxFramerate = 24

    static func iceServers() -> [RTCIceServer] {
        var servers: [RTCIceServer] = [
            RTCIceServer(urlStrings: AppConfig.shared.stunServers)
        ]

        let host = AppConfig.shared.turnHost
        let secret = AppConfig.shared.turnSecret
        if !host.isEmpty, !secret.isEmpty {
            let creds = turnCredentials(secret: secret)
            servers.append(
                RTCIceServer(
                    urlStrings: [
                        "turn:\(host):3478?transport=udp",
                        "turn:\(host):3478?transport=tcp",
                        "turns:\(host):5349?transport=tcp"
                    ],
                    username: creds.username,
                    credential: creds.password
                )
            )
        }
        return servers
    }

    /// coturn REST credential: username is an expiry timestamp, password is
    /// base64(HMAC-SHA1(secret, username)).
    private static func turnCredentials(secret: String, ttl: Int = 86_400) -> (username: String, password: String) {
        let expiry = Int(Date().timeIntervalSince1970) + ttl
        let username = "\(expiry):savevision"
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<Insecure.SHA1>.authenticationCode(for: Data(username.utf8), using: key)
        return (username, Data(mac).base64EncodedString())
    }
}
