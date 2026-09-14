import SwiftUI
import AIUsageCore

func quotaColor(_ remaining: Double, blocked: Bool = false) -> Color { blocked || remaining <= 5 ? .red : remaining <= 20 ? .orange : .accentColor }

struct MenuBarLabel: View {
    var store: UsageStore
    var body: some View {
        HStack(spacing: 4) {
            if store.settings.showPercent, !store.enabledAccounts.isEmpty {
                percentages.monospacedDigit()
            } else {
                Image(systemName: store.allFailed ? "exclamationmark.triangle" : "gauge.with.dots.needle.33percent").symbolRenderingMode(.monochrome)
            }
        }.fixedSize().help(accessibilitySummary)
            .accessibilityLabel(L("Quota restant"))
            .accessibilityValue(accessibilitySummary)
    }
    // MenuBarExtra extracts a single Text for the native status item.
    private var percentages: Text {
        var result = Text("")
        for (accountIndex, account) in store.enabledAccounts.enumerated() {
            if accountIndex > 0 { result = result + Text("  |  ").foregroundColor(.secondary) }
            result = result + Text(Image(systemName: account.provider.symbol)) + Text(" ")
            let usage = store.states[account.id]?.usage
            if let value = usage?.remainingPercent(at: store.now) {
                let blocked = usage?.windows.contains { $0.severity == .blocked } == true
                result = result + Text(usage?.remainingPercentText(at: store.now) ?? "—")
                    .foregroundColor(blocked || value <= 5 ? .red : value <= 20 ? .orange : .primary)
            } else { result = result + Text("—") }
        }
        return result
    }
    private var accessibilitySummary: String {
        store.enabledAccounts.map { account in
            let usage = store.states[account.id]?.usage
            let value = usage?.remainingPercent(at: store.now)
            return account.displayName + ": " + (value.map {
                "\(Int($0.rounded())) " + L("pour cent restants")
                    + (usage?.hasUnconfirmedReset(at: store.now) == true ? " — " + L("Réinitialisation non confirmée") : "")
            } ?? "—")
        }.joined(separator: "; ")
    }
}
struct GaugeRow: View {
    let window: UsageWindow
    let now: Date
    var body: some View {
        let percent = window.remainingPercent(at: now)
        let reset = window.unconfirmedReset(at: now)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(window.displayLabel()).font(.caption).lineLimit(2).frame(width: 100, alignment: .leading)
                GeometryReader { geometry in
                    Capsule().fill(.quaternary)
                        .overlay(alignment: .leading) { Capsule().fill(quotaColor(percent, blocked: window.severity == .blocked)).frame(width: geometry.size.width * percent / 100) }
                }.frame(height: 7)
                Text("\(Int(percent.rounded())) %").font(.caption.monospacedDigit()).frame(width: 37, alignment: .trailing)
                if window.isActive && [.warning, .critical, .blocked].contains(window.severity) && !reset {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).foregroundStyle(.orange)
                }
            }
            if reset { Text(L("Réinitialisation non confirmée")).font(.system(size: 10)).foregroundStyle(.secondary) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(window.displayLabel() + (reset ? " — " + L("Réinitialisation non confirmée") : ""))
        .accessibilityValue("\(Int(percent.rounded())) " + L("pour cent restants"))
        .help(window.resetsAt.map { L("Réinitialisation") + " : " + $0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(appLocale())) } ?? L("Réinitialisation inconnue"))
    }
}
struct AccountSection: View {
    var store: UsageStore
    let account: Account
    var body: some View {
        let state = store.states[account.id]
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: account.provider.symbol)
                Text(account.displayName).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(plan(state?.usage?.identity)).font(.caption).foregroundStyle(.secondary)
                if store.active[account.id] != nil || state?.isRenewing == true { ProgressView().controlSize(.mini) }
            }
            if let email = state?.usage?.identity?.email { Text(email).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled) }
            if let date = store.identityChanged[account.id], store.now.timeIntervalSince(date) < 86400 { Text(L("Identité changée")).font(.caption2).foregroundStyle(.orange) }
            if let usage = state?.usage {
                if usage.identity?.plan == "apiKey" { Text(L("Compte API, pas de quota d’abonnement")).font(.caption).foregroundStyle(.secondary) }
                else if usage.windows.isEmpty { Text(L("Aucune fenêtre de quota disponible")).font(.caption).foregroundStyle(.secondary) }
                ForEach(Array(usage.windows.enumerated()), id: \.element.id) { index, window in
                    if let group = window.group, index == 0 || usage.windows[index - 1].group != group {
                        Text(group).font(.caption2.weight(.medium)).foregroundStyle(.secondary).padding(.top, 2)
                    }
                    GaugeRow(window: window, now: store.now).opacity(state?.isOK == true ? 1 : 0.6)
                }
                HStack(spacing: 4) {
                    if let reset = usage.representative?.resetsAt { Text(resetLabel(reset, now: store.now)) }
                    Spacer(minLength: 2)
                    Text(String(format: L("maj il y a %d min"), locale: appLocale(), max(0, Int(store.now.timeIntervalSince(usage.fetchedAt) / 60))))
                        .foregroundStyle(store.now.timeIntervalSince(usage.fetchedAt) > 3 * max(account.provider.minimumInterval, store.settings.interval) ? Color.red : .secondary)
                }.font(.system(size: 10)).foregroundStyle(.secondary)
            }
            if let message = state?.message { Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
            if store.connecting.contains(account.id) { Text(L("Terminez la connexion dans le Terminal, puis cliquez sur Vérifier.")).font(.caption).foregroundStyle(.secondary) }
            if let state, state.offersReconnect || store.connecting.contains(account.id) {
                HStack {
                    if case .cliMissing(let provider) = state {
                        Link(L("Installer…"), destination: provider.installURL)
                    } else {
                        Button(L("Reconnecter…")) { Task { await store.login(account) } }
                        Button(L("Vérifier")) { Task { await store.refresh(.account, only: account.id) } }
                    }
                }.controlSize(.small)
            }
        }
    }
    private func plan(_ identity: AccountIdentity?) -> String {
        if identity?.tier?.contains("20x") == true { return "Max 20x" }
        if identity?.tier?.contains("5x") == true { return "Max 5x" }
        return identity?.plan == "apiKey" ? "API" : identity?.plan?.capitalized ?? ""
    }
}
func resetLabel(_ date: Date, now: Date) -> String {
    let seconds = date.timeIntervalSince(now)
    if seconds <= 0 { return L("Réinitialisation à confirmer") }
    if seconds < 86400 { return L("réinit. dans") + " \(Int(seconds / 3600)) h \(Int(seconds / 60) % 60)" }
    return L("réinit.") + " " + date.formatted(.dateTime.weekday(.abbreviated).hour().minute().locale(appLocale()))
}
struct PopoverView: View {
    @Bindable var store: UsageStore
    @Environment(\.openSettings) private var openSettings
    var only: UUID?
    private var accounts: [Account] { store.enabledAccounts.filter { only == nil || $0.id == only } }
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                if !store.enabledAccounts.isEmpty {
                    Text(L("Quota restant")).font(.caption).foregroundStyle(.secondary)
                }
                if store.enabledAccounts.isEmpty {
                    Image(systemName: "gauge.with.dots.needle.33percent").font(.largeTitle).foregroundStyle(.secondary)
                    Text(L("Vos quotas, en un coup d’œil")).font(.headline)
                    Text(L("Ajoutez un compte dans les réglages.")).foregroundStyle(.secondary).font(.callout)
                    Button(L("Ajouter un compte"), action: showSettings)
                }
                ForEach(accounts) { account in
                    AccountSection(store: store, account: account)
                    if account.id != accounts.last?.id { Divider() }
                }
                if !store.online { Label(L("Hors ligne — dernières valeurs connues"), systemImage: "wifi.slash").font(.caption).foregroundStyle(.secondary) }
                if let error = store.storageError { Text(error).font(.caption).foregroundStyle(.red) }
            }.padding(16)
            Divider()
            VStack(spacing: 8) {
                HStack {
                    Button { Task { await store.refresh(.manual, only: only) } } label: { Label(L("Actualiser"), systemImage: "arrow.clockwise") }
                        .keyboardShortcut("r").disabled(store.isRefreshing)
                    Spacer()
                    if let until = store.deferred.values.max(), until > store.now { Text(L("possible dans") + " \(Int(ceil(until.timeIntervalSince(store.now)))) s").font(.caption2).foregroundStyle(.secondary) }
                }
                HStack {
                    Button(L("Réglages…"), action: showSettings).keyboardShortcut(",")
                    Spacer()
                    Button(L("Quitter")) { NSApp.terminate(nil) }.keyboardShortcut("q")
                }
            }.buttonStyle(.plain).padding(14)
        }.frame(width: 320).fixedSize(horizontal: false, vertical: true).background(.regularMaterial)
        .onAppear { if store.lastRefresh.map({ Date().timeIntervalSince($0) > 60 }) ?? true { Task { await store.refresh(.popover, only: only) } } }
    }
    private func showSettings() {
        NSApp.activate(ignoringOtherApps: true)
        openSettings()
        if let window = NSApp.windows.first(where: { $0.identifier == SettingsWindowActivation.identifier }) {
            SettingsWindowActivation.bringToFront(window)
        }
    }

}
