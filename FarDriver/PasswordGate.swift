//
//  PasswordGate.swift
//  参数页 / 自学习页的密码验证
//
//  密码校验只在本机进行，不联网。
//

import SwiftUI

/// 简单的密码闸门：验证通过才显示内容
struct PasswordGate<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    @State private var input = ""
    @State private var unlocked = false
    @State private var wrong = false
    @State private var attempts = 0
    @FocusState private var focused: Bool

    /// 本机密码（可以在这里改）
    private let password = "3.1415926"

    var body: some View {
        Group {
            if unlocked {
                content()
            } else {
                lockedView
            }
        }
    }

    private var lockedView: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "lock.shield")
                .font(.system(size: 52))
                .foregroundStyle(.cyan)

            Text(title)
                .font(.title3.bold())

            Text("需要密码才能进入")
                .font(.caption)
                .foregroundStyle(.secondary)

            SecureField("输入密码", text: $input)
                .textFieldStyle(.plain)
                .keyboardType(.decimalPad)
                .multilineTextAlignment(.center)
                .font(.system(size: 20, design: .monospaced))
                .padding()
                .background(Color(white: 0.15))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 50)
                .focused($focused)
                .onSubmit { check() }

            if wrong {
                Text("密码不对，再试一次（已错 \(attempts) 次）")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button {
                check()
            } label: {
                Text("进入")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.cyan)
                    .foregroundStyle(.black)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .padding(.horizontal, 50)
            .disabled(input.isEmpty)

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.06).ignoresSafeArea())
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                focused = true
            }
        }
    }

    private func check() {
        if input == password {
            withAnimation {
                unlocked = true
            }
        } else {
            attempts += 1
            wrong = true
            input = ""
            focused = true
        }
    }
}
