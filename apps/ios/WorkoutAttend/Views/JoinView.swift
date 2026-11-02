import SwiftUI

struct JoinView: View {
    @Environment(AppModel.self) private var model
    @State private var name = ""
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty && !code.isEmpty && !busy
    }

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            VStack(spacing: 8) {
                Text("🏋️").font(.system(size: 56))
                Text("헬스 출첵").font(.largeTitle.bold())
                Text("\(Gym.name)에 오늘 갔는지\n친구들끼리 확인해요.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                TextField("이름 (친구들이 볼 이름)", text: $name)
                    .textContentType(.nickname)
                    .autocorrectionDisabled()
                    .padding()
                    .background(.background, in: .rect(cornerRadius: 12))
                SecureField("가입 코드", text: $code)
                    .textInputAutocapitalization(.never)
                    .padding()
                    .background(.background, in: .rect(cornerRadius: 12))
                    .onSubmit(submit)

                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }

                Button(action: submit) {
                    Group {
                        if busy { ProgressView().tint(.white) } else { Text("시작하기").bold() }
                    }
                    .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(!canSubmit)

                Text("이미 가입했다면 같은 이름으로 다시 들어오면 돼요.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Spacer()
        }
        .padding(24)
        .background(Color(.systemGroupedBackground))
    }

    private func submit() {
        guard canSubmit else { return }
        busy = true
        error = nil
        Task {
            defer { busy = false }
            do {
                try await model.join(name: name.trimmingCharacters(in: .whitespaces), code: code)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

#Preview {
    JoinView().environment(AppModel())
}
