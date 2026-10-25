import Foundation
import NetworkExtension

enum JFError: LocalizedError {
    case binaryNotFound, xrayNotReady, socketFail, badConfig
    var errorDescription: String? {
        switch self {
        case .binaryNotFound: return "找不到 xray 引擎"
        case .xrayNotReady: return "xray 启动失败"
        case .socketFail: return "隧道套接字错误"
        case .badConfig: return "节点配置无效"
        }
    }
}

/// NEPacketTunnelProvider：xray loopback(UDP datagram=IP packet) ↔ 系统隧道
/// 签名对齐 Xcode 16 SDK：startTunnel(options:completionHandler:) / stopTunnel(with:completionHandler:)
/// 数据流：readPacketsWithCompletionHandler 拉系统包→Go循环; Go回包→packetFlow.writePackets
final class JifengTunnel: NEPacketTunnelProvider {
    private var xrayPID: pid_t = 0
    private var udpFD: Int32 = -1
    private var tmpFiles: [URL] = []
    private var running = false

    // MARK: - 启动
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        running = true
        guard let nodeJSON = options?["node"] as? String,
              let node = NodeCodex.decode(nodeJSON)
        else {
            completionHandler(JFError.badConfig)
            return
        }
        do {
            try startXray(node: node)
        } catch {
            completionHandler(error)
            return
        }
        // 虚拟网卡设置：MTU 1400、假 IP、全流量进隧道
        let s4 = NEIPv4Route.default()
        let settings = try! NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "198.18.0.1")
        settings.mtu = NSNumber(value: 1400)
        let v4 = NEIPv4Settings(addresses: ["198.18.0.1"], subnetMasks: ["255.255.255.0"])
        v4.includedRoutes = [s4]
        v4.excludedRoutes = []
        settings.iPv4Settings = v4
        let dns = NEDNSSettings(servers: ["8.8.8.8", "1.1.1.1"])
        settings.dnsSettings = dns
        setTunnelNetworkSettings(settings) { err in
            if let err = err {
                completionHandler(err)
                return
            }
            self.readLoop()
            completionHandler(nil)
        }
    }

    // MARK: - 停止
    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        running = false
        killXray()
        completionHandler()
    }

    // MARK: - 读循环：系统给我们的包 → xray loopback
    private func readLoop() {
        packetFlow.readPackets { packets, protocols in
            if self.running {
                for p in packets {
                    self.udpSend(p)
                }
            }
            self.readLoop()
        }
    }

    // MARK: - 写循环：xray loopback 的响应 → 系统
    private func writeLoop() {
        DispatchQueue.global().async {
            var buf = [UInt8](repeating: 0, count: 1500)
            while self.running && self.udpFD >= 0 {
                let n = buf.withUnsafeMutableBytes { ptr -> Int in
                    guard let base = ptr.baseAddress else { return 0 }
                    return recv(self.udpFD, base, 1500, 0)
                }
                if n > 0 && self.running {
                    let data = Data(bytes: buf, count: n)
                    self.packetFlow.writePackets([data], withProtocols: [AF_INET as NSNumber])
                }
            }
        }
    }

    private func udpSend(_ data: Data) {
        guard udpFD >= 0 else { return }
        data.withUnsafeBytes { ptr in
            guard let base = ptr.baseAddress else { return }
            _ = send(udpFD, base, data.count, 0)
        }
    }

    // MARK: - xray 引擎
    private func startXray(node: ProxyNode) throws {
        let cfg = XrayConfig.json(for: node)
        let tmp = FileManager.default.temporaryDirectory
        let cfgURL = tmp.appendingPathComponent("jifeng_xray.json")
        let logURL = tmp.appendingPathComponent("jifeng_xray.log")
        try cfg.write(to: cfgURL, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        tmpFiles = [cfgURL, logURL]
        guard let bin = locateXray() else { throw JFError.binaryNotFound }
        guard let pid = spawnXray(bin: bin, config: cfgURL.path, log: logURL.path) else {
            throw JFError.xrayNotReady
        }
        // 等 loopback 端口就绪（UDP 用 connect 可达性替代 listen）
        var ok = false
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.25)
            if udpLoopbackReady() { ok = true; break }
        }
        if !ok {
            kill(pid, SIGKILL); var st: Int32 = 0; waitpid(pid, &st, 0)
            throw JFError.xrayNotReady
        }
        xrayPID = pid
        udpFD = makeUDPSocket()
        writeLoop()
    }

    private func killXray() {
        if xrayPID > 0 {
            kill(xrayPID, SIGTERM)
            Thread.sleep(forTimeInterval: 0.5)
            kill(xrayPID, SIGKILL)
            var st: Int32 = 0
            waitpid(xrayPID, &st, 0)
        }
        xrayPID = 0
        if udpFD >= 0 { close(udpFD); udpFD = -1 }
        for f in tmpFiles { try? FileManager.default.removeItem(at: f) }
        tmpFiles.removeAll()
    }

    private func spawnXray(bin: URL, config: String, log: String) -> pid_t? {
        let logFD = log.withCString { open($0, O_WRONLY | O_CREAT | O_APPEND, mode_t(0o644)) }
        var actions = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&actions)
        if logFD >= 0 {
            posix_spawn_file_actions_adddup2(&actions, Int32(logFD), 1)
            posix_spawn_file_actions_adddup2(&actions, Int32(logFD), 2)
        }
        let c0 = strdup(bin.path), c1 = strdup("run"), c2 = strdup("-config"), c3 = strdup(config)
        var argv: [UnsafeMutablePointer<CChar>?] = [c0, c1, c2, c3, nil]
        var env: [UnsafeMutablePointer<CChar>?] = [nil]
        var pid: pid_t = 0
        let rc = bin.path.withCString { cpath in
            posix_spawn(&pid, cpath, &actions, nil, &argv, &env)
        }
        free(c0); free(c1); free(c2); free(c3)
        posix_spawn_file_actions_destroy(&actions)
        if logFD >= 0 { close(logFD) }
        return rc == 0 ? pid : nil
    }

    private func makeUDPSocket() -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return -1 }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var rtv = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &rtv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(55555).bigEndian
        var ip = in_addr()
        inet_pton(AF_INET, "127.0.0.1", &ip)
        addr.sin_addr = ip
        let ret = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if ret != 0 { close(fd); return -1 }
        return fd
    }

    private func udpLoopbackReady() -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(55555).bigEndian
        var ip = in_addr()
        inet_pton(AF_INET, "127.0.0.1", &ip)
        addr.sin_addr = ip
        let ret = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return ret == 0
    }

    private func locateXray() -> URL? {
        let bundle = Bundle(for: type(of: self))
        let fm = FileManager.default
        let u0 = bundle.bundleURL.appendingPathComponent("xray")
        if fm.isExecutableFile(atPath: u0.path) { return u0 }
        if let u = bundle.resourceURL?.appendingPathComponent("xray"),
           fm.isExecutableFile(atPath: u.path) { return u }
        let u2 = Bundle.main.bundleURL.appendingPathComponent("PlugIns/Jifeng.appex/xray")
        if fm.isExecutableFile(atPath: u2.path) { return u2 }
        return nil
    }
}
