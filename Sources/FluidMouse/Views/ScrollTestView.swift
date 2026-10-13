import SwiftUI

struct ScrollTestView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Experimente aqui").font(.headline)
            Text("Role com a rodinha sobre esta lista. Pause e ative para comparar.")
                .font(.caption).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(1...60, id: \.self) { index in
                        HStack(spacing: 14) {
                            Text(String(format: "%02d", index)).monospacedDigit().foregroundStyle(.secondary)
                            RoundedRectangle(cornerRadius: 3).fill(.teal.opacity(Double(index % 5 + 1) / 7))
                                .frame(width: CGFloat(80 + index % 7 * 38), height: 6)
                            Spacer()
                            Text("Rolagem suave").font(.caption).foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 14).frame(height: 38)
                        Divider()
                    }
                }
            }
            .frame(height: 132)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }
}
