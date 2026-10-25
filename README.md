# 疾风 Jifeng — 加速器（AdHoc）

SwiftUI 主 App + NEPacketTunnelProvider 隧道扩展 + 内嵌 xray-core v26.10.21（darwin/arm64，CI 生成）。
协议：vless / vmess / shadowsocks 分享链接导入，全流量走节点。

## 安装
1. 打开 <https://yoyo520956.github.io/jifeng-ios/> 点「安装疾风」
   （或点 [ota.plist](dts/ota.plist)，iPhone 上需 Safari 打开 itms-services 链接）
2. 安装：设置 → 通用 → VPN 与设备管理 → 信任 "ruixian chen"
3. 开 App 点连接（首次系统会请求 VPN 授权）

若 GitHub Pages 未生效，请手动：仓库 Settings → Pages → Source 选 main / (root)。

## 安全材料
证书与描述文件只存于 Actions Secrets（JIFENG_P12_B64 / JIFENG_P12_PASSWORD /
JIFENG_PROFILE_B64），不进仓库。AdHoc 绑定 1 台设备，有效期至 2027-10-13。

## 免责声明
游戏内使用加速器存在封号风险，请自行决定使用。

## CI
.github/workflows/build.yml：xray(ubuntu-24.04) → app(macos-15)：
vtool 平台补丁(iOS 15.0) + ad-hoc codesign → keychain/描述文件 →
xcodegen → archive → exportArchive(ad-hoc) → 守卫检查（unzip -l + 字节级中文特征）→
Release v1.0.0 资产 Jifeng.ipa。
