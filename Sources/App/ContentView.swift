import SwiftUI

struct ContentView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        TabView(selection: $app.tab) {
            HomeView()
                .tabItem { Label("首页", systemImage: "bolt.fill") }
                .tag(AppTab.home)
            NodesView()
                .tabItem { Label("节点", systemImage: "network") }
                .tag(AppTab.nodes)
            AboutView()
                .tabItem { Label("关于", systemImage: "info.circle") }
                .tag(AppTab.about)
        }
        .tint(.cyan)
        .preferredColorScheme(.dark)
    }
}

struct HomeView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        NavigationStack {
            VStack(spacing: 26) {
                nodeHeader
                toggleButton
                metrics
                statusText
                Spacer()
            }
            .padding(20)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("疾风加速")
            .alert(app.toast ?? "", isPresented: Binding(
                get: { app.toast != nil },
                set: { if !$0 { app.toast = nil } }
            )) {
                Button("好", role: .cancel) { }
            }
            .onChange(of: app.toast) { _ in
                if app.toast != nil {
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 3_500_000_000)
                        app.toast = nil
                    }
                }
            }
        }
    }

    var nodeHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("当前节点").font(.caption).foregroundStyle(.gray)
                Text(app.currentNode?.name ?? "未选择节点")
                    .font(.title3.weight(.semibold))
                if let n = app.currentNode {
                    Text("\(n.proto) · \(n.host):\(n.port) · \(n.network)")
                        .font(.caption2).foregroundStyle(.gray)
                }
            }
            Spacer()
            Menu {
                ForEach(app.nodes) { n in
                    let isDef = app.defaultNodeID == n.id
                    Button(n.name) {
                        app.setDefault(n.id)
                        if isDef && !app.isConnected { app.connect() }
                    }
                }
            } label: {
                Image(systemName: "chevron.down")
            }
            .frame(width: 44, height: 44)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(white: 0.08)))
        }
    }

    var toggleButton: some View {
        Button {
            if app.isConnected { app.disconnect() } else { app.connect() }
        } label: {
            ZStack {
                Circle()
                    .fill(app.isConnected ? Color.cyan.opacity(0.15) : Color(white: 0.08))
                    .frame(width: 170, height: 170)
                    .overlay(Circle().strokeBorder(
                        app.isConnected ? Color.cyan : Color.cyan.opacity(0.35),
                        lineWidth: 4))
                Image(systemName: "bolt.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(app.isConnected ? Color.cyan : Color.gray)
            }
        }
        .buttonStyle(.plain)
        .disabled(app.status == .connecting)
    }

    var metrics: some View {
        HStack(spacing: 12) {
            MetricCard(title: "延迟",
                      value: app.latencyMs.map { String(format: "%.0f", $0) } ?? "--",
                      unit: "ms")
            MetricCard(title: "下行", value: String(format: "%.2f", app.downMBs), unit: "MB/s")
            MetricCard(title: "上行", value: String(format: "%.2f", app.upMBs), unit: "MB/s")
        }
    }

    var statusText: some View {
        Group {
            switch app.status {
            case .disconnected:
                Label("已断开", systemImage: "power")
                    .foregroundStyle(.gray)
            case .connecting:
                Label("连接中…", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.cyan)
            case .connected:
                Label("已连接 · 全流量走节点", systemImage: "wifi")
                    .foregroundStyle(.green)
            case .error(let m):
                Label(m, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
        }
        .font(.callout.weight(.medium))
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

struct MetricCard: View {
    let title: String
    let value: String
    let unit: String

    var body: some View {
        VStack(spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.gray)
            Text(value)
                .font(.system(size: 30, weight: .bold, design: .monospaced))
                .foregroundStyle(.cyan)
            Text(unit).font(.caption2).foregroundStyle(.gray)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(white: 0.08)))
    }
}
