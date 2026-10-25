import Foundation
import NetworkExtension

enum JifengError: LocalizedError {
    case binaryNotFound
    case xrayNotReady
    case socketFail
    case recvFail

    var errorDescription: String? {
        switch self {
        case .binaryNotFound: return "找不到 xray 引擎"
        case .xrayNotReady: return "xray 启动失败"
        case .socketFail: return "隧道套接字错误"
        case .recvFail: return "读取隧道数据失败"
        }
    }
}

/// NEPacketTunnelProvider：桥接 xray loopback(127.0.0.1:55555) 与系统隧道
/// 协议：每个 UDP datagram = 一个 IP 包（xray loopback inbound）
final class JifengTunnel: NEPacketTunnelProvider {
    private var xrayProcess: Process?
    private var udpFD: Int32 = -1
    private var tmpFiles: [URL] = []

    // MARK: - 启动（legacy completion 版签名，iOS 14+）
    override func startTunnel(options: [String: NSObject]?, completion: @escaping (Error?) -> Void) {
        super.setTunnelMTU(1400)
        guard let nodeJSON = options?["node"] as? String,
              let node = NodeCodex.decode(nodeJSON)
        else {
            completion(JifengError.binaryNotFound)
            return
        }
        do {
            try setupXray(node: node)
        } catch {
            completion(error)
            return
        }
        completion(nil)
    }

    // MARK: - 停止
    override func stopTunnel(reason: NEProviderStopReason, completion: @escaping (Error?) -> Void) {
        if let p = xrayProcess {
            p.terminate()
            let deadline = Date().addingTimeInterval(3)
            while p.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        }
        xrayProcess = nil
        if udpFD >= 0 {
            close(udpFD)
            udpFD = -1
        }
        for f in tmpFiles { try? FileManager.default.removeItem(at: f) }
        tmpFiles.removeAll()
        self.completion(nil)
    }

    // MARK: - 数据桥
    override func writeTunnelData(_ packet: NEPacketTunnelProvider.TunnelPacket) async throws {
        let data = packet.content
        guard udpFD >= 0 else { throw JifengError.socketFail }
        var sent = 0
        var retry = 0
        while sent < data.count {
            let n = data.withUnsafeBytes { ptr -> Int in
                guard let base = ptr.baseAddress else { return 0 }
                return send(udpFD, base.assumingMemoryBound(to: UInt8.self).advanced(by: sent),
                            data.count - sent, 0)
            }
            if n > 0 {
                sent += n
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                retry += 1
                if retry > 10 { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            break // 其它错误，放弃本包
        }
    }

    override func readTunnelData(count: Int, completion: @escaping (Data?, Error?) -> Void) {
        guard udpFD >= 0 else {
            completion(nil, JifengError.socketFail)
            return
        }
        let cap = max(count, 16)
        var buf = [UInt8](repeating: 0, count: cap)
        let n = buf.withUnsafeMutableBytes { ptr -> Int in
            guard let base = ptr.baseAddress else { return 0 }
            return recvp(udpFD, base, UInt32(cap), 0, nil, nil)
        }
        if n > 0 {
            completion(Data(bytes: buf, count: n), nil)
        } else if errno == EAGAIN || errno == EWOULDBLOCK {
            completion(nil, nil)
        } else {
            completion(nil, JifengError.recvFail)
        }
    }

    // MARK: - xray 引擎
    private func setupXray(node: ProxyNode) throws {
        let cfg = XrayConfig.json(for: node)
        let tmp = FileManager.default.temporaryDirectory
        let cfgURL = tmp.appendingPathComponent("jifeng_xray.json")
        let logURL = tmp.appendingPathComponent("jifeng_xray.log")
        try cfg.write(to: cfgURL, atomically: true, encoding: .utf8)
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        tmpFiles = [cfgURL, logURL]

        guard let bin = locateXray() else { throw JifengError.binaryNotFound }
        let proc = Process()
        proc.executableURL = bin
        proc.arguments = ["run", "-config", cfgURL.path]
        if let fh = FileHandle(forWritingAtPath: logURL.path) {
            proc.standardOutput = fh
            proc.standardError = fh
        }
        try proc.run()

        // 轮询 ≤5s：进程活着 + loopback 端口能发出
        var ok = false
        for _ in 0..<20 {
            Thread.sleep(forTimeInterval: 0.25)
            if !proc.isRunning { break }
            if udpReachable() { ok = true; break }
        }
        guard ok, proc.isRunning else {
            proc.terminate()
            throw JifengError.xrayNotReady
        }
        xrayProcess = proc
        udpFD = makeUDPSocket()
    }

    private func locateXray() -> URL? {
        let bundle = Bundle(for: type(of: self))
        let fm = FileManager.default
        if let u = bundle.bundleURL?.appendingPathComponent("xray"),
           fm.isExecutableFile(atPath: u.path) {
            return u
        }
        if let u = bundle.resourceURL?.appendingPathComponent("xray"),
           fm.isExecutableFile(atPath: u.path) {
            return u
        }
        if let u = Bundle.main.bundleURL?.appendingPathComponent("PlugIns/Jifeng.appex/xray"),
           fm.isExecutableFile(atPath: u.path) {
            return u
        }
        return nil
    }

    private func makeUDPSocket() -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return -1 }
        var tv = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        fcntl(fd, F_SETFL, O_NONBLOCK)
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
        if ret != 0 {
            close(fd)
            return -1
        }
        return fd
    }

    private func udpReachable() -> Bool {
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
}
