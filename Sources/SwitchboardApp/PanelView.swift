import SwiftUI
import SwitchboardCore

// Name the property wrapper explicitly; newer SDKs also export a State macro.
private typealias ViewState<Value> = SwiftUI.State<Value>

private enum QuotaPalette {
    static func color(for remaining: Double) -> Color {
        switch remaining {
        case ...10: return .red
        case ...25: return .orange
        case ...50: return .yellow
        case ...75: return .cyan
        default: return .green
        }
    }
}

struct PanelView: View {
    @ObservedObject var model: PanelModel
    var quit: () -> Void
    var initiallyExpandedCredits = false
    @ViewState private var contentHeight: CGFloat = 180
    private var language: AppLanguage { model.language }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Text("Codex Switchboard").font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.refreshing {
                    ProgressView().controlSize(.mini).accessibilityLabel(language.text("Refreshing accounts"))
                    Text(language.text("Refreshing…")).font(.caption).foregroundStyle(.secondary).fixedSize()
                }
                Button(action: model.refreshClicked) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help(language.text("Refresh all accounts"))
                    .accessibilityLabel(language.text("Refresh all accounts"))
                    .disabled(model.refreshing || model.busyText != nil)
            }
            if let status = model.currentStatus {
                Text(language.message(status))
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 10) {
                    if model.accounts.isEmpty {
                        VStack(spacing: 7) {
                            Image(systemName: "person.crop.circle.badge.plus").font(.title2).foregroundStyle(.secondary)
                            Text(language.text("Add your Codex accounts")).font(.subheadline.weight(.medium))
                            Text(language.text("Sign in once to view usage and switch accounts."))
                                .font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity).padding(.vertical, 18)
                    }
                    ForEach(model.accounts) { account in
                        AccountCard(account: account, state: model.states[account.id] ?? .loading,
                                    current: model.currentID == account.id,
                                    enabled: model.canAct, removable: model.canRemove(account),
                                    switchAccount: { model.switchAccount(account) },
                                    signIn: { model.signIn(account) }, remove: { model.remove(account) },
                                    initiallyExpandedCredits: initiallyExpandedCredits)
                    }
                }
                .frame(maxWidth: .infinity).fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    // Ignore transient zero measurements while the popover is detached.
                    if height > 0 { contentHeight = height }
                }
            }
            .frame(height: min(max(contentHeight, 100), 490))
            .accessibilityIdentifier("account-overview")

            if let busy = model.busyText {
                HStack(spacing: 7) {
                    ProgressView().controlSize(.mini)
                    Text(language.message(busy)).font(.caption).fixedSize(horizontal: false, vertical: true)
                    if model.signingIn {
                        Spacer(minLength: 0)
                        Button(language.text("Cancel"), action: model.cancelSignIn).controlSize(.small)
                    }
                }
            }
            if let notice = model.notice {
                HStack(alignment: .top, spacing: 8) {
                    Text(language.message(notice)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).font(.caption2).help(language.text("Dismiss"))
                }
            }
            if model.showRecovery {
                Button(language.text("Recover Interrupted Operation"), action: model.recover).disabled(model.busyText != nil)
            }
            HStack {
                SettingsMenu(model: model)
                Spacer()
                Button(language.text("Quit"), action: quit).buttonStyle(.borderless)
                    .keyboardShortcut("q").disabled(model.busyText != nil || model.refreshing)
            }
            .font(.caption).controlSize(.small)
        }
        .padding(12).frame(width: 380)
        .environment(\.switchboardLanguage, language)
    }
}

struct AccountCard: View {
    let account: SavedAccount
    let state: CardState
    let current: Bool
    let enabled: Bool
    let removable: Bool
    let switchAccount: () -> Void
    let signIn: () -> Void
    let remove: () -> Void
    var renderingPreview = false
    var initiallyExpandedCredits = false
    @Environment(\.colorScheme) private var scheme
    @Environment(\.switchboardLanguage) private var language

    private var color: Color {
        guard case .available(let usage) = state, let remaining = usage.quotas.map(\.remaining).min() else { return .gray }
        return QuotaPalette.color(for: remaining)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(account.email).font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle).help(account.email)
                Spacer(minLength: 0)
                if case .signIn = state {
                    Button(language.text("Sign In"), action: signIn).buttonStyle(CompactActionStyle()).disabled(!enabled)
                } else if current {
                    CurrentBadge()
                } else {
                    Button(language.text("Switch"), action: switchAccount).buttonStyle(CompactActionStyle()).disabled(!enabled)
                }
                if renderingPreview { Image(systemName: "ellipsis").frame(width: 15) }
                else {
                    Menu {
                        Button(language.text("Remove Account"), role: .destructive, action: remove).disabled(!removable)
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18)
                        .help(language.text(current ? "The current account cannot be removed" : "Account actions"))
                        .accessibilityLabel(language.format("Actions for %@", account.email))
                }
            }
            Text(language.text(PlanLabel.text(account.plan))).font(.caption).foregroundStyle(.secondary)
            switch state {
            case .loading:
                Text(language.text("Refreshing…")).font(.caption).foregroundStyle(.secondary)
            case .unavailable:
                Text(language.text("Unavailable")).font(.caption).foregroundStyle(.secondary)
            case .signIn:
                Text(language.text("Sign in required")).font(.caption).foregroundStyle(.secondary)
            case .available(let usage):
                if usage.quotas.isEmpty { Text(language.text("Unavailable")).font(.caption).foregroundStyle(.secondary) }
                ForEach(usage.quotas) { quota in QuotaRow(quota: quota) }
                ResetCreditsView(usage: usage, initiallyExpanded: initiallyExpandedCredits)
            }
        }
        .padding(11).frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .controlBackgroundColor))
                .overlay { RoundedRectangle(cornerRadius: 10).fill(color.opacity(scheme == .dark ? 0.10 : 0.045)) }
        }
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(color.opacity(scheme == .dark ? 0.34 : 0.25), lineWidth: 1) }
        .accessibilityElement(children: .contain)
    }
}

private struct CurrentBadge: View {
    @Environment(\.switchboardLanguage) private var language
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "crown.fill").font(.system(size: 10, weight: .semibold))
            Text(language.text("Current")).font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(Color(red: 0.25, green: 0.14, blue: 0.025))
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(LinearGradient(colors: [
                    Color(red: 1, green: 0.88, blue: 0.51),
                    Color(red: 0.94, green: 0.69, blue: 0.22)
                ], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color(red: 0.67, green: 0.43, blue: 0.09).opacity(0.65), lineWidth: 0.5)
                }
                .shadow(color: Color(red: 0.6, green: 0.37, blue: 0.02).opacity(0.18), radius: 2, y: 1)
        }
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(language.text("Current account"))
    }
}

struct CompactActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.caption).padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.primary.opacity(configuration.isPressed ? 0.12 : 0.045), in: RoundedRectangle(cornerRadius: 5))
            .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(Color.primary.opacity(0.13), lineWidth: 0.5) }
            .opacity(enabled ? 1 : 0.45)
    }
}

struct CardPreview: View {
    @ObservedObject var model: PanelModel
    var expandedCredits = false
    private var language: AppLanguage { model.language }
    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                Text("Codex Switchboard").font(.system(size: 13, weight: .semibold))
                Spacer(); Image(systemName: "arrow.clockwise")
            }
            ForEach(model.accounts) { account in
                AccountCard(account: account, state: model.states[account.id] ?? .unavailable,
                            current: model.currentID == account.id, enabled: true, removable: true,
                            switchAccount: {}, signIn: {}, remove: {}, renderingPreview: true,
                            initiallyExpandedCredits: expandedCredits)
            }
            HStack { Label(language.text("Settings"), systemImage: "gearshape"); Spacer(); Text(language.text("Quit")) }.font(.caption)
        }.padding(12).frame(width: 380)
            .environment(\.switchboardLanguage, language)
    }
}

private struct QuotaRow: View {
    let quota: Quota
    @Environment(\.switchboardLanguage) private var language
    private var color: Color { QuotaPalette.color(for: quota.remaining) }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(language.quotaTitle(quota.title)).lineLimit(1).help(language.quotaTitle(quota.title))
                Spacer(minLength: 4)
                Text(language.format("%@%% left", quota.remaining.formatted(.number.precision(.fractionLength(0...1)).locale(language.locale))))
                    .fontWeight(.semibold).monospacedDigit()
            }.font(.caption)
            HStack(spacing: 8) {
                GeometryReader { geometry in
                    Capsule().fill(.quaternary)
                        .overlay(alignment: .leading) {
                            Capsule().fill(color).frame(width: geometry.size.width * quota.remaining / 100)
                        }
                }.frame(width: 60, height: 3)
                    .accessibilityLabel("\(language.quotaTitle(quota.title)): \(language.format("%@%% left", String(Int(quota.remaining))))")
                if let reset = quota.resetsAt {
                    Text(language.format("Resets %@", language.date(reset)))
                        .help(language.date(reset, complete: true))
                } else { Text(language.text("Reset time unavailable")) }
            }.font(.caption2).foregroundStyle(.secondary)
        }
    }
}

struct SettingsMenu: View {
    @ObservedObject var model: PanelModel
    private var language: AppLanguage { model.language }

    var body: some View {
        Menu {
            Button { model.signIn() } label: {
                Label(language.text("Add Account"), systemImage: "plus")
            }.disabled(!model.canAct)
            Divider()
            Picker(language.text("Language"), selection: $model.language) {
                ForEach(AppLanguage.allCases) { option in
                    Text(option.nativeName).tag(option)
                }
            }.pickerStyle(.menu)
        } label: {
            Label(language.text("Settings"), systemImage: "gearshape")
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityIdentifier("settings-menu")
    }
}
