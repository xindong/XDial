import SwiftUI

/// 设置：语言切换 + 配置状态信息 + 不引人注目的 debug 手测入口。
///
/// debug 入口：一行普通的「版本」文字，**长按**（遥控器中键按住）才触发
/// DebugSmokeTest.run()，普通点击无反应。只在 DEBUG 构建里挂长按手势，
/// release 构建下就是一行纯展示文字，不暴露手测能力。
struct SettingsView: View {
    @EnvironmentObject private var app: AppState

    /// 最近一次手测结果，长按触发后回填展示。
    @State private var smokeResult: String = ""

    var body: some View {
        Form {
            Section { CloudConfigurationSettings(sync: app.cloudSync, chinese: app.language == .zh) }
            languageSection
            Toggle(app.tr("换网络后自动连回", "Reconnect when the network changes"), isOn: $app.systemOnDemandEnabled)
            statusSection
            privacySection
            debugSection
        }
        .navigationTitle(app.tr("设置", "Settings"))
    }

    // MARK: - 语言

    private var languageSection: some View {
        Section {
            Picker(app.tr("语言", "Language"), selection: $app.language) {
                Text("简体中文").tag(Lang.zh)
                Text("English").tag(Lang.en)
            }
        } header: {
            Text(app.tr("外观", "Appearance"))
        }
    }

    // MARK: - 状态信息（纯数据派生）

    private var statusSection: some View {
        Section {
            infoRow(
                label: app.tr("连接描述文件", "Connection profile"),
                value: app.helperInstalled
                    ? app.tr("已安装", "Installed")
                    : app.tr("未安装", "Not installed")
            )
            infoRow(
                label: app.tr("场景数量", "Scenarios"),
                value: "\(app.profile.scenarios.count)"
            )
            infoRow(
                label: app.tr("线路数量", "Lines"),
                value: "\(app.profile.lines.count)"
            )
            infoRow(
                label: app.tr("连接状态", "Connection"),
                value: app.statusText
            )
        } header: {
            Text(app.tr("状态", "Status"))
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - 数据使用说明

    private var privacySection: some View {
        Section {
            NavigationLink {
                TVDataUseNoticeView(mode: .review)
            } label: {
                Text(app.tr("数据使用说明", "Data Use Notice"))
            }
            .accessibilityIdentifier("settings-data-use")
            infoRow(label: app.tr("隐私政策", "Privacy Policy"), value: TVDataUseNoticeView.privacyPolicyAddress)
        } header: {
            Text(app.tr("隐私", "Privacy"))
        }
    }

    // MARK: - 隐藏 debug 入口

    @ViewBuilder
    private var debugSection: some View {
        Section {
            let versionRow = HStack {
                Text(app.tr("版本", "Version"))
                Spacer()
                Text("0.4.1 (tvOS)")
                    .foregroundStyle(.secondary)
            }

            #if DEBUG
            versionRow
                .onLongPressGesture(minimumDuration: 1.0) {
                    smokeResult = app.tr("正在运行手测…", "Running smoke test…")
                    DebugSmokeTest.run { line in
                        smokeResult = line
                    }
                }
            if !smokeResult.isEmpty {
                HStack {
                    Text(app.tr("手测", "Smoke test"))
                    Spacer()
                    Text(smokeResult)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            #else
            versionRow
            #endif
        } header: {
            Text(app.tr("关于", "About"))
        }
    }
}
