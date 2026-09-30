import SwiftUI
import SwitchboardCore

// Name the property wrapper explicitly; newer SDKs also export a State macro.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct PanelView: View {
    @ObservedObject var model: PanelModel
    var quit: () -> Void
    var initiallyExpandedCredits = false
    @ViewState private var contentHeight: CGFloat = 180

    var body: some View {
        if let review = model.setupReview {
            VStack(alignment: .leading, spacing: 12) {
                Text("Review shared setup").font(.headline)
                Text("Choose the version all accounts will use. Your chats stay with each account.")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        ForEach(review.conflicts) { conflict in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(conflict.name).font(.subheadline.weight(.semibold))
                                Text(conflict.kind).font(.caption).foregroundStyle(.secondary)
                                Picker("Use settings from", selection: Binding(
                                    get: { model.setupChoices[conflict.id] ?? conflict.defaultChoice },
                                    set: { model.setupChoices[conflict.id] = $0 })) {
                                    ForEach(conflict.choices) { choice in Text(choice.label).tag(choice.id) }
                                }.labelsHidden()
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(height: min(CGFloat(review.conflicts.count) * 90, 380))
                HStack {
                    Button("Cancel", action: model.cancelSetupReview)
                    Spacer()
                    Button("Apply and Switch", action: model.confirmSetupReview).buttonStyle(.borderedProminent)
                }.controlSize(.small)
            }.padding(12).frame(width: 380)
        } else {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 8) {
                Text("Codex Switchboard").font(.system(size: 13, weight: .semibold))
                Spacer()
                if model.refreshing {
                    ProgressView().controlSize(.mini).accessibilityLabel("Refreshing accounts")
                    Text("Refreshing…").font(.caption).foregroundStyle(.secondary).fixedSize()
                }
                Button(action: model.refreshClicked) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh all accounts")
                    .accessibilityLabel("Refresh all accounts")
                    .disabled(model.refreshing || model.busyText != nil)
            }
            if model.currentID == nil {
                Text(model.currentStatus)
                    .font(.caption).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 10) {
                    if model.accounts.isEmpty {
                        VStack(spacing: 7) {
                            Image(systemName: "person.crop.circle.badge.plus").font(.title2).foregroundStyle(.secondary)
                            Text("Add your Codex accounts").font(.subheadline.weight(.medium))
                            Text("Sign in once to view usage and switch accounts.")
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
                    Text(busy).font(.caption).fixedSize(horizontal: false, vertical: true)
                    if model.signingIn {
                        Spacer(minLength: 0)
                        Button("Cancel", action: model.cancelSignIn).controlSize(.small)
                    }
                }
            }
            if let notice = model.notice {
                HStack(alignment: .top, spacing: 8) {
                    Text(notice).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button { model.notice = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain).font(.caption2).help("Dismiss")
                }
            }
            HStack {
                Button { model.signIn() } label: { Label("Add Account", systemImage: "plus") }
                    .buttonStyle(.borderless).disabled(!model.canAct)
                Spacer()
                Button("Quit", action: quit).buttonStyle(.borderless)
                    .keyboardShortcut("q").disabled(model.busyText != nil || model.refreshing)
            }
            .font(.caption).controlSize(.small)
        }
        .padding(12).frame(width: 380)
        }
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

    private var color: Color {
        guard case .available(let usage) = state, let remaining = usage.quotas.map(\.remaining).min() else { return .gray }
        return remaining <= 10 ? .red : remaining <= 25 ? .orange : .green
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 7) {
                Text(account.email).font(.system(size: 13, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle).help(account.email)
                Spacer(minLength: 0)
                if case .signIn = state {
                    Button("Sign In", action: signIn).buttonStyle(CompactActionStyle()).disabled(!enabled)
                } else if current {
                    CurrentBadge()
                } else {
                    Button("Switch", action: switchAccount).buttonStyle(CompactActionStyle()).disabled(!enabled)
                }
                if renderingPreview { Image(systemName: "ellipsis").frame(width: 15) }
                else {
                    Menu {
                        Button("Remove Account", role: .destructive, action: remove).disabled(!removable)
                    } label: { Image(systemName: "ellipsis") }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 18)
                        .help(current ? "The current account cannot be removed" : "Account actions")
                        .accessibilityLabel("Actions for \(account.email)")
                }
            }
            Text(PlanLabel.text(account.plan)).font(.caption).foregroundStyle(.secondary)
            switch state {
            case .loading:
                Text("Refreshing…").font(.caption).foregroundStyle(.secondary)
            case .unavailable:
                Text("Unavailable").font(.caption).foregroundStyle(.secondary)
            case .signIn:
                Text("Sign in required").font(.caption).foregroundStyle(.secondary)
            case .available(let usage):
                if usage.quotas.isEmpty { Text("Unavailable").font(.caption).foregroundStyle(.secondary) }
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
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "crown.fill").font(.system(size: 10, weight: .semibold))
            Text("Current").font(.system(size: 11, weight: .bold))
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
        .accessibilityLabel("Current account")
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
            HStack { Label("Add Account", systemImage: "plus"); Spacer(); Text("Quit") }.font(.caption)
        }.padding(12).frame(width: 380)
    }
}

private struct QuotaRow: View {
    let quota: Quota
    private var color: Color { quota.remaining <= 10 ? .red : quota.remaining <= 25 ? .orange : .green }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(quota.title).lineLimit(1).help(quota.title)
                Spacer(minLength: 4)
                Text("\(quota.remaining.formatted(.number.precision(.fractionLength(0...1))))% left")
                    .fontWeight(.semibold).monospacedDigit()
            }.font(.caption)
            HStack(spacing: 8) {
                GeometryReader { geometry in
                    Capsule().fill(.quaternary)
                        .overlay(alignment: .leading) {
                            Capsule().fill(color).frame(width: geometry.size.width * quota.remaining / 100)
                        }
                }.frame(width: 60, height: 3)
                    .accessibilityLabel("\(quota.title): \(Int(quota.remaining)) percent remaining")
                if let reset = quota.resetsAt {
                    Text("Resets \(reset.formatted(.dateTime.month(.abbreviated).day().hour().minute().locale(Locale(identifier: "en_US"))))")
                        .help(reset.formatted(Date.FormatStyle(date: .complete, time: .standard, locale: Locale(identifier: "en_US"))))
                } else { Text("Reset time unavailable") }
            }.font(.caption2).foregroundStyle(.secondary)
        }
    }
}
