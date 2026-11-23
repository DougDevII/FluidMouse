import SwiftUI
import AppKit

/// Pequeno sistema de design compartilhado pelas telas: cartões, cabeçalhos de
/// seção e escalas de espaçamento. Tudo usa cores e materiais do sistema, para
/// acompanhar o claro/escuro do macOS sem esforço extra.
enum Design {
    static let corner: CGFloat = 12
    static let cardPadding: CGFloat = 16
    static let sectionSpacing: CGFloat = 18
    /// Accent segue a cor de destaque escolhida pelo sistema (decisão
    /// declarada da célula UI-01, aprovada pelo líder): nada de teal fixo.
    static let accent = Color.accentColor
}

/// Cartão padrão: fundo com o material de controle do sistema, cantos
/// arredondados e um fio de separação sutil.
struct CardBackground: ViewModifier {
    var padding: CGFloat = Design.cardPadding
    var tint: Color?

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Design.corner, style: .continuous)
                    .fill(tint ?? Color(nsColor: .controlBackgroundColor))
                    .overlay {
                        RoundedRectangle(cornerRadius: Design.corner, style: .continuous)
                            .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
                    }
            }
    }
}

extension View {
    func card(padding: CGFloat = Design.cardPadding, tint: Color? = nil) -> some View {
        modifier(CardBackground(padding: padding, tint: tint))
    }
}

/// Cabeçalho de seção: ícone, título e uma linha de apoio.
struct SectionHeader: View {
    let symbol: String
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Design.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

/// Rótulo de estado em formato de "pilula", usado nos cartões de status.
struct StatusChip: View {
    let text: String
    var symbol: String?
    var tint: Color = Design.accent

    var body: some View {
        HStack(spacing: 4) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 10, weight: .bold))
            }
            Text(text).font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
    }
}

/// Linha de rótulo/valor usada nos cartões de resumo.
struct SummaryRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: monospaced ? .monospaced : .default))
                .textSelection(.enabled)
        }
    }
}

/// Cartão de permissão de Acessibilidade, no topo do detail de qualquer aba
/// enquanto `controller.trusted == false`. Única ação: abrir Ajustes do
/// Sistema — sem retry genérico.
struct PermissionCard: View {
    @ObservedObject var controller: AppController

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "hand.raised.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 8) {
                Text("Permita suavizar a rolagem")
                    .font(.system(size: 14, weight: .semibold))
                Text("Em Ajustes do Sistema → Privacidade e Segurança → Acessibilidade, ative o FluidMouse. Depois disso, o status da rolagem suave mostra se a suavização está funcionando.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Abrir Acessibilidade…") { controller.grantPermission() }
                    .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .card(tint: Color.orange.opacity(0.10))
        .accessibilityElement(children: .combine)
    }
}

/// Banner global de erro: consome `controller.errorMessage` com botão
/// Dispensar. **Sem retry genérico** — o retry contextual (reler/reconectar)
/// entra onde a operação é conhecida (aba Mouse, UI-04).
struct ErrorBanner: View {
    @ObservedObject var controller: AppController

    var body: some View {
        if let message = controller.errorMessage {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.red)
                Text(message)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Dispensar") { controller.errorMessage = nil }
                    .controlSize(.small)
            }
            .card(tint: Color.red.opacity(0.10))
            .accessibilityElement(children: .combine)
        }
    }
}

/// Indicador pequeno de operação de escrita em curso na aba Mouse, ligado
/// **apenas** ao snapshot do tracker de operações (`controller.rapooOperations`
/// por id existente). Nada é inferido de mudanças de `status` — pending só
/// existe enquanto o callback não chega. Consumido a partir da UI-02/UI-04.
struct PendingMarker: View {
    let operations: [String: RapooOperationTracker.Snapshot]
    let id: String
    var label = "aplicando…"

    var pending: Bool { operations[id]?.outcome == .pending }

    var body: some View {
        if pending {
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// Selo "Não confirmado": aparece somente quando o tracker registra falha ou
/// interrupção para a operação nomeada. Não afirma que o mouse ficou sem a
/// alteração: uma falha de leitura de volta pode ter gravado parcialmente.
/// Nunca aparece sobre um sucesso ou sobre uma operação pendente.
struct NotAppliedChip: View {
    let operations: [String: RapooOperationTracker.Snapshot]
    let id: String

    var failed: Bool {
        guard let outcome = operations[id]?.outcome else { return false }
        if case .failure = outcome { return true }
        return outcome == .interrupted
    }

    var body: some View {
        if failed {
            StatusChip(text: "Não confirmado", symbol: "questionmark.circle", tint: .orange)
        }
    }
}
