import SwiftUI

struct AboutView: View {
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    row("版本", "1.0.0 (20261025.01)")
                    row("引擎", "xray-core v26.10.21 · arm64")
                    row("签名", "AdHoc · 有效期至 2027-10-13")
                    row("证书", "iPhone Distribution: ruixian chen")
                    row("BundleID", "app.jujube1760.cassava8287")
                    Label("游戏内使用加速器存在封号风险，请自行决定使用。",
                          systemImage: "exclamationmark.shield")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                        .padding(.top, 8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("关于")
        }
    }

    private func row(_ t: String, _ v: String) -> some View {
        HStack(alignment: .top) {
            Text(t).font(.caption).foregroundStyle(.gray)
                .frame(width: 70, alignment: .leading)
            Text(v).font(.subheadline)
        }
    }
}
