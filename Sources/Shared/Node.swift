import Foundation

/// 代理节点模型（App 与隧道扩展共用）
public struct ProxyNode: Codable, Identifiable, Hashable {
    public var id: UUID
    public var name: String
    public var proto: String       // vless / vmess / shadowsocks
    public var host: String
    public var port: Int
    public var uuid: String
    public var flow: String
    public var security: String    // none / tls / reality
    public var sni: String
    public var pbk: String
    public var sid: String
    public var fp: String
    public var network: String     // tcp / ws / grpc
    public var wsPath: String
    public var wsHost: String
    public var grpcService: String
    public var password: String
    public var cipher: String
    public var alterId: Int

    public init(id: UUID = UUID(), name: String, proto: String, host: String, port: Int,
                uuid: String = "", flow: String = "", security: String = "", sni: String = "",
                pbk: String = "", sid: String = "", fp: String = "", network: String = "tcp",
                wsPath: String = "", wsHost: String = "", grpcService: String = "",
                password: String = "", cipher: String = "", alterId: Int = 0) {
        self.id = id; self.name = name; self.proto = proto; self.host = host; self.port = port
        self.uuid = uuid; self.flow = flow; self.security = security; self.sni = sni
        self.pbk = pbk; self.sid = sid; self.fp = fp; self.network = network
        self.wsPath = wsPath; self.wsHost = wsHost; self.grpcService = grpcService
        self.password = password; self.cipher = cipher; self.alterId = alterId
    }
}

/// 分享链接解析：vless:// vmess:// ss://（逐行，多条）
public enum NodeParser {
    public static func parse(_ text: String) -> (nodes: [ProxyNode], skipped: [String]) {
        var nodes: [ProxyNode] = []
        var skipped: [String] = []
        for line in text.split(whereSeparator: { "\n\r".contains($0) }) {
            let l = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !l.isEmpty else { continue }
            if let n = parseOne(l) {
                nodes.append(n)
            } else {
                let short = l.count > 44 ? String(l.prefix(44)) + "…" : l
                skipped.append(short)
            }
        }
        return (nodes, skipped)
    }

    static func parseOne(_ s: String) -> ProxyNode? {
        if s.hasPrefix("vless://") { return vless(s) }
        if s.hasPrefix("vmess://") { return vmess(s) }
        if s.hasPrefix("ss://") { return ss(s) }
        return nil
    }

    // MARK: vless
    static func vless(_ s: String) -> ProxyNode? {
        var rest = String(s.dropFirst(8))
        var name = "vless 节点"
        if let h = rest.firstIndex(of: "#") {
            name = percentDecode(String(rest[rest.index(after: h)...]))
            rest = String(rest[..<h])
        }
        guard let at = rest.firstIndex(of: "@") else { return nil }
        let uuid = String(rest[..<at])
        var hp = String(rest[rest.index(after: at)...])
        var query = ""
        if let qm = hp.firstIndex(of: "?") {
            query = String(hp[hp.index(after: qm)...])
            hp = String(hp[..<qm])
        }
        var host = hp
        var port = 443
        if let c = hp.firstIndex(of: ":") {
            host = String(hp[..<c])
            port = Int(String(hp[hp.index(after: c)...])) ?? 443
        }
        var p: [String: String] = [:]
        for kv in query.split(separator: "&") {
            guard let i = kv.firstIndex(of: "=") else { continue }
            p[percentDecode(String(kv[..<i]))] = percentDecode(String(kv[kv.index(after: i)...]))
        }
        return ProxyNode(name: name, proto: "vless", host: host, port: port,
                         uuid: uuid,
                         flow: p["flow"] ?? "",
                         security: p["security"] ?? "none",
                         sni: p["sni"] ?? "",
                         pbk: p["pbk"] ?? "",
                         sid: p["sid"] ?? "",
                         fp: p["fp"] ?? "",
                         network: p["type"] ?? "tcp",
                         wsPath: p["path"] ?? "",
                         wsHost: p["host"] ?? "",
                         grpcService: p["serviceName"] ?? "")
    }

    // MARK: vmess
    static func vmess(_ s: String) -> ProxyNode? {
        let b64 = String(s.dropFirst(8))
        guard let data = b64data(b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        guard let add = s2(obj["add"]), let id = s2(obj["id"]) else { return nil }
        let port = Int(s2(obj["port"]) ?? "443") ?? 443
        var net = s2(obj["net"]) ?? "tcp"
        if net == "wss" { net = "ws" }
        guard ["tcp", "ws", "grpc"].contains(net) else { return nil }
        var security = s2(obj["scy"]) ?? "auto"
        if security == "none" { security = "" }
        if s2(obj["tls"]) == "tls" && security.isEmpty { security = "tls" }
        if s2(obj["type"]) == "wss" && security.isEmpty { security = "tls" }
        return ProxyNode(name: s2(obj["ps"]) ?? "vmess 节点", proto: "vmess",
                         host: add, port: port,
                         uuid: id,
                         alterId: Int(s2(obj["aid"]) ?? "0") ?? 0,
                         security: security,
                         sni: s2(obj["sni"]) ?? "",
                         fp: s2(obj["fp"]) ?? "",
                         network: net,
                         wsHost: s2(obj["host"]) ?? "",
                         wsPath: s2(obj["path"]) ?? "",
                         grpcService: s2(obj["serviceName"]) ?? "")
    }

    // MARK: ss
    static func ss(_ s: String) -> ProxyNode? {
        var rest = String(s.dropFirst(5))
        var name = "ss 节点"
        if let h = rest.firstIndex(of: "#") {
            name = percentDecode(String(rest[rest.index(after: h)...]))
            rest = String(rest[..<h])
        }
        guard let at = rest.firstIndex(of: "@") else { return nil }
        var cred = String(rest[..<at])
        if let d = b64data(cred), let str = String(data: d, encoding: .utf8) {
            guard let i = str.firstIndex(of: ":") else { return nil }
            let method = String(str[..<i])
            cred = String(str[str.index(after: i)...])
            var hostPort = String(rest[rest.index(after: at)...])
            var port = 8388
            var host = hostPort
            if let c = hostPort.firstIndex(of: ":") {
                host = String(hostPort[..<c])
                port = Int(String(hostPort[hostPort.index(after: c)...])) ?? 8388
            }
            return ProxyNode(name: name, proto: "shadowsocks", host: host, port: port,
                             cipher: method, password: cred)
        }
        // 未 base64 的 method:password 直写
        if let i = cred.firstIndex(of: ":") {
            let method = String(cred[..<i])
            cred = String(cred[cred.index(after: i)...])
            var hostPort = String(rest[rest.index(after: at)...])
            var port = 8388
            var host = hostPort
            if let c = hostPort.firstIndex(of: ":") {
                host = String(hostPort[..<c])
                port = Int(String(hostPort[hostPort.index(after: c)...])) ?? 8388
            }
            return ProxyNode(name: name, proto: "shadowsocks", host: host, port: port,
                             cipher: method, password: cred)
        }
        return nil
    }

    // MARK: helpers
    static func percentDecode(_ s: String) -> String {
        s.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? s
    }
    static func b64data(_ s: String) -> Data? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.count % 4 != 0 { t += "=" }
        return Data(base64Encoded: t)
    }
    static func s2(_ v: Any?) -> String? {
        switch v {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }
}
