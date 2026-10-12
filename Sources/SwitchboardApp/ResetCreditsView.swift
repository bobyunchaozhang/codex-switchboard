import SwiftUI
import SwitchboardCore

private typealias CreditViewState<Value> = SwiftUI.State<Value>

struct ResetCreditsView: View {
    let usage: Usage
    @Environment(\.switchboardLanguage) private var language
    @CreditViewState private var expanded: Bool

    init(usage: Usage, initiallyExpanded: Bool = false) {
        self.usage = usage
        _expanded = CreditViewState(initialValue: initiallyExpanded)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let now = context.date
            VStack(alignment: .leading, spacing: 8) {
                if let count = usage.resetCount {
                    if count > 0 || !(usage.resetCredits ?? []).isEmpty {
                        Button { expanded.toggle() } label: {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text(summary(count: count, now: now))
                                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 0)
                                Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(summary(count: count, now: now)). \(language.text(expanded ? "Hide reset details" : "Show reset details"))")
                        if expanded { details(now: now) }
                    } else { Text(language.text("0 resets available")) }
                } else { Text(language.text("Reset count unavailable")) }
            }.font(.caption).foregroundStyle(.secondary)
        }
    }

    private func summary(count: Int, now: Date) -> String {
        let countText = language.format(count == 1 ? "%d reset available" : "%d resets available", count)
        guard count > 0 else { return countText }
        if let date = usage.nextCreditExpiry(at: now) {
            let prefix = usage.hasIncompleteCreditDetails(at: now) ? "Next known expiry" : count == 1 ? "Expires" : "Next expiry"
            return "\(countText) · \(language.text(prefix)) \(language.date(date))"
        }
        let suffix = usage.hasIncompleteCreditDetails(at: now) ? "Expiry unavailable" : "Does not expire"
        return "\(countText) · \(language.text(suffix))"
    }

    @ViewBuilder private func details(now: Date) -> some View {
        if let credits = usage.resetCredits, !credits.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(credits.enumerated()), id: \.element.id) { index, credit in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(credit.title.flatMap { $0.isEmpty ? nil : language.text($0) } ?? language.format("Reset %d", index + 1))
                                .fontWeight(.medium).lineLimit(2)
                            Spacer(minLength: 4)
                            if let status = credit.status, status != "available" {
                                Text(language.text(status == "redeemed" ? "Used" : status == "redeeming" ? "In use" : "Status unknown")).font(.caption2)
                            }
                        }
                        switch credit.expiry {
                        case .at(let date):
                            Text("\(language.text(date <= now ? "Expired" : "Expires")) \(language.date(date))")
                                .font(.caption2).help(language.date(date, complete: true))
                        case .never: Text(language.text("Does not expire")).font(.caption2)
                        case .unknown: Text(language.text("Expiry unavailable")).font(.caption2)
                        }
                    }
                    .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6))
                }
                if usage.hasIncompleteCreditDetails(at: now) {
                    Text(language.text("Some reset details are unavailable.")).font(.caption2)
                }
            }
        } else {
            Text(language.text(usage.resetCredits == nil ? "Reset details unavailable" : "No reset details reported"))
                .font(.caption2)
        }
    }

}
