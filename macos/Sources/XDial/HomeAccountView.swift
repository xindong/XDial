import SwiftUI

struct HomeAccountRequest: Codable, Hashable {
    let lineID: String
    var connectScenarioID: String?
}

struct HomeAccountView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss
    let request: HomeAccountRequest
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var confirmingSignOut = false
    @State private var saveError: String?
    @State private var formHeight: CGFloat = 270

    private var line: Line? { state.profile.lines.first { $0.id == request.lineID } }
    private var owner: ProfileRecord? { state.profileLibrary.owner(ofLine: request.lineID) }
    private var sourceOwned: Bool { owner?.baseline?.lines.contains { $0.id == request.lineID } == true }
    private var editable: Bool {
        line != nil && !state.isBusy && !state.isConnected && (!sourceOwned || owner?.lineCredentialsBelongToUser == true)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            ScrollView {
                fields
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { formHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(formHeight, 380))
            HStack {
                if let line, !line.vpnUsername.isEmpty || !line.vpnPassword.isEmpty,
                   !sourceOwned || owner?.lineCredentialsBelongToUser == true {
                    Button(state.tr("退出账号", "Sign Out"), role: .destructive) { confirmingSignOut = true }
                        .disabled(!editable)
                }
                Spacer()
                Button(state.tr("取消", "Cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(request.connectScenarioID == nil ? state.tr("保存", "Save") : state.tr("保存并连接", "Save and Connect")) {
                    submit()
                }
                .xdialPrimaryAction()
                .keyboardShortcut(.defaultAction)
                .disabled(!editable || server.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                          username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(XDialPalette.canvas)
        .onAppear {
            server = line?.vpnServer ?? ""
            username = line?.vpnUsername ?? ""
            password = line?.vpnPassword ?? ""
        }
        .onDisappear { password = "" }
        .alert(state.tr("退出这条线路的账号？", "Sign out of this line?"), isPresented: $confirmingSignOut) {
            Button(state.tr("取消", "Cancel"), role: .cancel) {}
            Button(state.tr("退出账号", "Sign Out"), role: .destructive) { submit(signingOut: true) }
        } message: {
            Text(state.tr("XDial 将清除此线路保存的用户名和密码。", "XDial will clear the username and password saved for this line."))
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 18) {
            if let line {
                HomeAccountHeading(title: state.tr("登录\(line.name)", "Sign in to \(line.name)"))
                VStack(alignment: .leading, spacing: 12) {
                    if sourceOwned && !line.vpnServer.isEmpty {
                        Label(line.vpnServer, systemImage: "server.rack")
                            .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                    } else {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(state.tr("服务器", "Server")).font(.subheadline)
                            TextField(state.tr("服务器", "Server"), text: $server)
                        }
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(state.tr("用户名", "Username")).font(.subheadline)
                        TextField(state.tr("用户名", "Username"), text: $username)
                            .textContentType(.username).autocorrectionDisabled()
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text(state.tr("密码", "Password")).font(.subheadline)
                        CredentialSecureField(placeholder: state.tr("密码", "Password"), text: $password)
                    }
                }
                .controlSize(.large)
                .disabled(!editable)
            }
            if sourceOwned && owner?.lineCredentialsBelongToUser == false {
                Text(state.tr("此账号由订阅提供。", "This account is managed by the subscription."))
            } else if state.isConnected || state.isBusy {
                Text(state.tr("断开连接后可修改账号。", "Disconnect to edit the account."))
            }
            if let saveError { Text(saveError).foregroundStyle(.red) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(3)
    }

    private func submit(signingOut: Bool = false) {
        guard editable, let index = state.profile.lines.firstIndex(where: { $0.id == request.lineID }) else { return }
        let previousLibrary = state.profileLibrary
        if !signingOut && (!sourceOwned || state.profile.lines[index].vpnServer.isEmpty) {
            state.profile.lines[index].vpnServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        state.profile.lines[index].vpnUsername = signingOut ? "" : username
        state.profile.lines[index].vpnPassword = signingOut ? "" : password
        state.profile.lines[index].verified = false
        state.save()
        if let error = state.profilePersistenceError {
            state.profileLibrary = previousLibrary
            state.profile = previousLibrary.snapshot()
            saveError = error
            return
        }
        dismiss()
        if !signingOut, let id = request.connectScenarioID { state.connectScenario(id) }
    }
}
