import Foundation
import Darwin

/// TCP 握手测延迟（主 App 直连节点 host:port，不经过隧道；纯 POSIX）
public enum LatencyProbe {
    public static func latency(to host: String, port: Int, timeout: Double = 4) -> Double? {
        let t0 = Date()
        var h = addrinfo()
        h.ai_family = AF_INET
        h.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &h, &res) == 0, let r = res else { return nil }
        defer { freeaddrinfo(r) }
        let fd = socket(r.pointee.ai_family, r.pointee.ai_socktype, r.pointee.ai_protocol)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        fcntl(fd, F_SETFL, O_NONBLOCK)
        guard connect(fd, r.pointee.ai_addr, r.pointee.ai_addrlen) == 0 || errno == EINPROGRESS else { return nil }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        var wfds = fdset()   // 全零 = 无 fd
        if fd < 32 { wfds.fds_bits.0 = Int32(1 << fd) }
        let rc = select(fd + 1, nil, &wfds, nil, &tv)
        guard rc >= 1 else { return nil }
        var err: Int32 = 0
        var elen = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &elen)
        guard err == 0 else { return nil }
        return Date().timeIntervalSince(t0) * 1000
    }
}

/// 节点配置序列化（主 App → 隧道扩展 经 options["node"]）
public enum NodeCodex {
    public static func encode(_ n: ProxyNode) -> String {
        guard let d = try? JSONEncoder().encode(n) else { return "{}" }
        return String(data: d, encoding: .utf8) ?? "{}"
    }
    public static func decode(_ s: String) -> ProxyNode? {
        try? JSONDecoder().decode(ProxyNode.self, from: Data(s.utf8))
    }
}

/// xray 配置生成（字段对齐 Xray-core v26；proxy 出向放第一位 = 全流量走节点）
public enum XrayConfig {
    public static func json(for node: ProxyNode) -> String {
        var stream: [String: Any] = [
            "network": node.network,
            "security": node.security.isEmpty ? "none" : node.security
        ]
        if !node.sni.isEmpty { stream["serverName"] = node.sni }
        if !node.fp.isEmpty { stream["fingerprint"] = node.fp }
        if !node.pbk.isEmpty { stream["publicKey"] = node.pbk }
        if !node.sid.isEmpty { stream["shortId"] = node.sid }
        if node.network == "ws" {
            var ws: [String: Any] = ["path": node.wsPath]
            if !node.wsHost.isEmpty { ws["host"] = node.wsHost }
            stream["wsSettings"] = ws
        }
        if node.network == "grpc" {
            stream["grpcSettings"] = ["serviceName": node.grpcService]
        }

        var settings: [String: Any]
        let proto: String
        switch node.proto {
        case "vmess":
            proto = "vmess"
            var user: [String: Any] = ["id": node.uuid]
            let scy = node.cipher.isEmpty ? "auto" : node.cipher
            user["security"] = scy
            if node.alterId > 0 { user["alterId"] = node.alterId }
            settings = ["vnext": [["address": node.host, "port": node.port, "users": [user]]]]
        default:
            proto = "vless"
            var user: [String: Any] = ["id": node.uuid, "encryption": "none"]
            if !node.flow.isEmpty { user["flow"] = node.flow }
            settings = ["vnext": [["address": node.host, "port": node.port, "users": [user]]]]
        }
        if node.proto == "shadowsocks" {
            proto = "shadowsocks"
            settings = ["servers": [[
                "address": node.host, "port": node.port,
                "method": node.cipher, "password": node.password
            ]]]
        }

        var outbound: [String: Any] = [
            "tag": "proxy", "protocol": proto, "settings": settings
        ]
        if !stream.isEmpty { outbound["streamSettings"] = stream }

        let cfg: [String: Any] = [
            "log": ["loglevel": "warning"],
            "api": ["tag": "api", "services": ["Stats"]],
            "policy": ["systemStats": true],
            "dns": ["servers": ["8.8.8.8", "1.1.1.1"]],
            "inbounds": [
                ["tag": "tun", "protocol": "loopback", "listen": "127.0.0.1",
                 "port": 55555, "settings": [String: Any]()],
                ["tag": "api", "protocol": "api", "listen": "127.0.0.1",
                 "port": 10809, "settings": [String: Any]()]
            ],
            "outbounds": [outbound,
                          ["tag": "direct", "protocol": "freedom", "settings": [String: Any]()]],
            "routing": ["domainStrategy": "AsIs", "rules": [String: Any]()]
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: cfg, options: [.fragmentsAllowed]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}

/// xray API（127.0.0.1:10809 jsonrpc）
public enum XrayAPI {
    public static func post(_ body: [String: Any]) async -> [String: Any]? {
        var req = URLRequest(url: URL(string: "http://127.0.0.1:10809/jsonrpc")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 4
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
