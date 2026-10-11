import SwiftUI

struct LoginView: View {
    @ObservedObject var model: AppModel
    @State private var serverAddress = ""
    @State private var secret = ""

    private var palette: EchoPalette { model.theme.palette }

    var body: some View {
        ZStack {
            palette.background.ignoresSafeArea()
            Circle()
                .fill(Color.white.opacity(model.theme == .harbor ? 0.04 : 0.30))
                .frame(width: 330, height: 330)
                .blur(radius: 2)
                .offset(x: 130, y: -300)

            VStack(spacing: 0) {
                Spacer()

                VStack(spacing: 18) {
                    ZStack {
                        Circle()
                            .fill(palette.composer)
                            .frame(width: 82, height: 82)
                            .shadow(color: Color.black.opacity(0.08), radius: 24, y: 12)
                        Image(systemName: "sparkles")
                            .font(.system(size: 30, weight: .light))
                            .foregroundStyle(palette.accent)
                    }

                    VStack(spacing: 7) {
                        Text("Tidal Echo")
                            .font(.system(size: 31, weight: .medium, design: .serif))
                            .foregroundStyle(palette.text)
                        Text("你和小克的私密频道")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(palette.secondaryText)
                    }
                }

                Spacer().frame(height: 48)

                VStack(spacing: 12) {
                    field(icon: "network", placeholder: "https://你的域名/relay", text: $serverAddress)

                    HStack(spacing: 12) {
                        Image(systemName: "key.horizontal")
                            .foregroundStyle(palette.secondaryText)
                            .frame(width: 20)
                        SecureField("连接密钥", text: $secret)
                            .textContentType(.password)
                            .foregroundStyle(palette.text)
                    }
                    .padding(.horizontal, 16)
                    .frame(height: 54)
                    .background(palette.composer, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 17).stroke(palette.hairline))

                    Button {
                        Task { await model.login(serverAddress: serverAddress, secret: secret) }
                    } label: {
                        HStack(spacing: 9) {
                            if model.phase == .connecting {
                                ProgressView().tint(Color.white)
                            }
                            Text(model.phase == .connecting ? "正在连接" : "进入频道")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 54)
                        .foregroundStyle(Color.white)
                        .background(palette.accent, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
                    }
                    .disabled(model.phase == .connecting || serverAddress.isEmpty || secret.isEmpty)
                }
                .padding(.horizontal, 26)

                Spacer()

                Text("密钥只保存在这台 iPhone 的钥匙串中")
                    .font(.footnote)
                    .foregroundStyle(palette.secondaryText.opacity(0.8))
                    .padding(.bottom, 18)
            }
        }
        .onAppear {
            if serverAddress.isEmpty { serverAddress = model.savedServerAddress }
        }
    }

    private func field(icon: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(palette.secondaryText)
                .frame(width: 20)
            TextField(placeholder, text: text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .foregroundStyle(palette.text)
        }
        .padding(.horizontal, 16)
        .frame(height: 54)
        .background(palette.composer, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 17).stroke(palette.hairline))
    }
}

