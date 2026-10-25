import SwiftUI
import NetworkExtension

enum AppTab: Hashable { case home, nodes, about }

enum TunnelStatus: Equatable {
    case disconnected
    case connecting
    case connected
    case error(String)
}

@MainActor
final class AppState: ObservableObject {
    @Published var tab: AppTab = .home
    @Published var status: TunnelStatus = .disconnected
    @Published var latencyMs: Double?
    @Published var downMBs = 0.0
    @Published var upMBs = 0.0
    @Published var nodes: [ProxyNode] = []
    @Published var defaultNodeID: UUID?
    @Published var toast: String?
    @Published var nodeLatency: [UUID: Double] = [:]

    let manager = NEPacketTunnelManager()
    private var connection: NETunnelConnection?
    private var pollTask: Task<Void, Never>?
    private var lastIn: Double?
    private var lastOut: Double?
    private var interval: TimeInterval = 2.0

    init() {
        load()
        startMonitor()
    }

    var isConnected: Bool { status == .connected }
    var currentNode: ProxyNode? {
        if let d = defaultNodeID, let n = nodes.first(where: { $0.id == d }) { return n }
        return nodes.first
    }

    // MARK: - 状态监视（每 1.5s 轮询；若 CI 报 "only available via await" 则改 await manager.connection）
    private func startMonitor() {
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let st = self.manager.connection.state
                self.apply(st)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
    }

    func apply(_ st: NETunnelConnectionState) {
        switch st {
        case .active:
            status = .connected
            if pollTask == nil { startPolling() }
        case .inactive:
            status = .disconnected
            stopPolling()
            downMBs = 0; upMBs = 0; latencyMs = nil
        case .error:
            status = .error("隧道错误")
            stopPolling()
        @unknown default:
            break
        }
    }

    // MARK: - 连接 / 断开
    func connect() {
        guard !isConnected else { return }
        guard let node = currentNode else {
            toast = "请先在节点管理里导入节点"
            return
        }
        defaultNodeID = node.id
        save()
        status = .connecting
        latencyMs = nil; downMBs = 0; upMBs = 0
        Task { @MainActor in
            do {
                let conn = try await self.manager.requestPacketTunnelConnection()
                self.connection = conn
                try await self.manager.startTunnel(conn, options: ["node": NodeCodex.encode(node)])
            } catch {
                self.status = .error("隧道启动失败：\(error.localizedDescription)")
                self.connection = nil
            }
        }
    }

    func disconnect() {
        stopPolling()
        guard let conn = connection else {
            status = .disconnected
            connection = nil
            return
        }
        connection = nil
        if #available(iOS 17.0, *) {
            Task { @MainActor in
                _ = try? await self.manager.stopTunnel(conn)
                if case .connected = self.status { self.status = .disconnected }
                if case .connecting = self.status { self.status = .disconnected }
            }
        } else {
            self.manager.stopTunnel(conn) { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if case .connected = self.status { self.status = .disconnected }
                    if case .connecting = self.status { self.status = .disconnected }
                }
            }
        }
    }

    // MARK: - 测速 / 流量（连上后每 2s 轮询 xray API）
    private func startPolling() {
        stopPolling()
        lastIn = nil; lastOut = nil
        interval = 2.0
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.pollOnce()
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func pollOnce() {
        // 自己保存的 connection 兜底
        if !isConnected, let c = connection {
            switch c.state {
            case .active: break
            case .inactive: status = .disconnected; stopPolling()
            case .error: status = .error("隧道已断开"); stopPolling()
            @unknown default: break
            }
            return
        }
        guard isConnected else { stopPolling(); return }

        // 延迟：TCP 握手探测（主 App 直连节点 host:port，不经过隧道）
        if let node = currentNode {
            Task { [weak self] in
                let ms = await LatencyProbe.latency(to: node.host, port: node.port)
                guard let self else { return }
                self.latencyMs = ms
                if let ms {
                    self.nodeLatency[node.id] = ms
                    self.save()
                }
            }
        }

        // 流量：queryStats（index 形式 outbound>0>）
        Task { [weak self] in
            async let dR: [String: Any]? = XrayAPI.post(["id": 1, "method": "queryStats", "params": ["outbound>0>downlink"]])
            async let uR: [String: Any]? = XrayAPI.post(["id": 2, "method": "queryStats", "params": ["outbound>0>uplink"]])
            guard let self else { return }
            func val(_ r: [String: Any]?) -> Double? {
                (r?["result"] as? [String: Any])?["value"] as? Double
            }
            let d = val(await dR), u = val(await uR)
            guard let d, let u else { return }
            if let li = lastIn, let lo = lastOut, li > 0, lo > 0, interval > 0 {
                self.downMBs = max(0, (d - li) / 8 / 1048576 / interval)
                self.upMBs = max(0, (u - lo) / 8 / 1048576 / interval)
            }
            lastIn = d; lastOut = u
        }
    }

    // MARK: - 节点管理
    func addImport(text: String) {
        let r = NodeParser.parse(text)
        nodes += r.nodes
        if defaultNodeID == nil { defaultNodeID = nodes.first?.id }
        save()
        var msg = "导入 \(r.nodes.count) 个节点"
        if !r.skipped.isEmpty {
            msg += "，跳过 \(r.skipped.count) 条（\(r.skipped.joined(separator: " / "))）"
        }
        toast = msg
    }
    func remove(_ id: UUID) {
        nodes.removeAll { $0.id == id }
        if defaultNodeID == id { defaultNodeID = nodes.first?.id }
        nodeLatency.removeValue(forKey: id)
        save()
    }
    func setDefault(_ id: UUID) {
        defaultNodeID = id
        save()
    }
    func testNode(_ n: ProxyNode) {
        toast = "正在测试 \(n.name)…"
        Task { [weak self] in
            let ms = await LatencyProbe.latency(to: n.host, port: n.port)
            guard let self else { return }
            if let ms {
                self.nodeLatency[n.id] = ms
                self.save()
                self.toast = "\(n.name)：\(Int(ms)) ms"
            } else {
                self.nodeLatency[n.id] = nil
                self.toast = "\(n.name)：无法连接"
            }
        }
    }

    // MARK: - 持久化
    private func dir() -> URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    }
    func load() {
        guard let d = dir() else { return }
        if let data = try? Data(contentsOf: d.appendingPathComponent("nodes.json")),
           let arr = try? JSONDecoder().decode([ProxyNode].self, from: data) {
            nodes = arr
        }
        if let data = try? Data(contentsOf: d.appendingPathComponent("def.json")),
           let uid = try? JSONDecoder().decode(UUID.self, from: data) {
            defaultNodeID = uid
        }
        if let data = try? Data(contentsOf: d.appendingPathComponent("lat.json")),
           let dict = try? JSONDecoder().decode([UUID: Double].self, from: data) {
            nodeLatency = dict
        }
    }
    func save() {
        guard let d = dir() else { return }
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(nodes) {
            try? data.write(to: d.appendingPathComponent("nodes.json"))
        }
        if let id = defaultNodeID, let data = try? JSONEncoder().encode(id) {
            try? data.write(to: d.appendingPathComponent("def.json"))
        }
        if let data = try? JSONEncoder().encode(nodeLatency) {
            try? data.write(to: d.appendingPathComponent("lat.json"))
        }
    }

    private var monitorTask: Task<Void, Never>?
}
