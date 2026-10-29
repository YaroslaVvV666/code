import SwiftUI
import Combine

/// Предупреждение «вы не сохранили». Экран-редактор помечает себя как «есть несохранённые изменения»,
/// а контейнер подэкранов, перехватывая «назад», показывает выбор: «Сохранить» или «Сбросить».
/// Устроено безопасно: «Сбросить/Не сохранять» уходит всегда, так что застрять на экране нельзя.
final class LeaveGuard: ObservableObject {
    static let shared = LeaveGuard()

    @Published var dirty = false          // редактор: есть несохранённые изменения
    @Published var saveSignal = 0         // контейнер просит редактор сохранить и выйти

    func markClean() { dirty = false }
}

// MARK: - Карточка «Несохранённые изменения» по центру экрана

/// Диалог несохранённых изменений — не системная шторка снизу, а своя карточка по центру экрана
/// (затемнение фона, тап мимо карточки — отмена).
private struct UnsavedChangesDialog: ViewModifier {
    @Binding var isPresented: Bool
    let title: String
    let message: String
    let saveTitle: String
    let discardTitle: String
    let onSave: () -> Void
    let onDiscard: () -> Void

    @Environment(\.theme) private var theme

    func body(content: Content) -> some View {
        content.overlay {
            if isPresented {
                ZStack {
                    Color.black.opacity(0.5).ignoresSafeArea()
                        .onTapGesture { withAnimation(.easeOut(duration: 0.2)) { isPresented = false } }
                    card
                        .transition(.scale(scale: 0.92).combined(with: .opacity))
                }
                .animation(.spring(response: 0.34, dampingFraction: 0.85), value: isPresented)
            }
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 21, weight: .bold)).foregroundStyle(theme.text)
            Text(message).font(.system(size: 16)).foregroundStyle(theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(spacing: 10) {
                Button {
                    isPresented = false; onSave()
                } label: {
                    Text(saveTitle).font(.system(size: 17, weight: .bold)).foregroundStyle(.white)
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(theme.accentColor, in: Capsule())
                }
                .buttonStyle(PressStyle())
                Button {
                    isPresented = false; onDiscard()
                } label: {
                    Text(discardTitle).font(.system(size: 17, weight: .semibold)).foregroundStyle(theme.text)
                        .frame(maxWidth: .infinity).frame(height: 54)
                        .background(theme.surface, in: Capsule())
                }
                .buttonStyle(PressStyle())
            }
            .padding(.top, 8)
        }
        .padding(22)
        .frame(maxWidth: 360)
        .background(theme.sheet, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 30, style: .continuous).stroke(theme.stroke, lineWidth: 0.6))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 10)
        .padding(.horizontal, 36)
    }
}

extension View {
    /// Карточка несохранённых изменений по центру экрана (замена системной шторки снизу)
    func unsavedChangesDialog(isPresented: Binding<Bool>, title: String, message: String,
                              saveTitle: String, discardTitle: String,
                              onSave: @escaping () -> Void, onDiscard: @escaping () -> Void) -> some View {
        modifier(UnsavedChangesDialog(isPresented: isPresented, title: title, message: message,
                                      saveTitle: saveTitle, discardTitle: discardTitle,
                                      onSave: onSave, onDiscard: onDiscard))
    }
}
