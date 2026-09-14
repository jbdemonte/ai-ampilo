import SwiftUI
import ServiceManagement
import AIUsageCore

// A menu bar app may open its Settings scene without becoming the active app.
// Capture the actual scene window so first opening and subsequent openings both focus it.
struct SettingsWindowActivation: NSViewRepresentable {
    static let identifier = NSUserInterfaceItemIdentifier("AIUsageSettings")
    static func bringToFront(_ window: NSWindow) {
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
    final class WindowReader: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.identifier = SettingsWindowActivation.identifier
            DispatchQueue.main.async { [weak window] in
                guard let window else { return }
                SettingsWindowActivation.bringToFront(window)
            }
        }
    }
    func makeNSView(context: Context) -> WindowReader { WindowReader() }
    func updateNSView(_ nsView: WindowReader, context: Context) {}
}

struct SettingsView: View {
    @Bindable var store: UsageStore
    var body: some View {
        TabView {
            GeneralTab(store: store).tabItem { Label(L("Général"), systemImage: "gearshape") }
            AccountsTab(store: store).tabItem { Label(L("Comptes"), systemImage: "person.2") }
            AdvancedTab(store: store).tabItem { Label(L("Avancé"), systemImage: "slider.horizontal.3") }
        }.padding(16).frame(width: 610, height: 530)
    }
}
struct GeneralTab: View {
    @Bindable var store: UsageStore
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var error: String?
    var body: some View {
        Form {
            Section(L("Actualisation")) {
                Picker(L("Intervalle"), selection: $store.settings.interval) {
                    ForEach([60, 120, 300, 600, 900, 1800], id: \.self) { seconds in Text("\(seconds / 60) min").tag(Double(seconds)) }
                }
                Toggle(L("Afficher le pourcentage dans la barre"), isOn: $store.settings.showPercent)
                Toggle(L("Un élément de barre par compte"), isOn: $store.settings.perAccountMenu)
            }
            Section(L("Notifications")) {
                Toggle(L("Alerte à 20 % restants"), isOn: $store.settings.notify80)
                Toggle(L("Alerte quand le quota est épuisé"), isOn: $store.settings.notify100)
            }
            Section {
                Toggle(L("Lancer à l’ouverture de session"), isOn: Binding(get: { loginStatus == .enabled }, set: { enabled in
                    do { if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                    catch { self.error = L("Impossible de modifier le lancement automatique") }
                    loginStatus = SMAppService.mainApp.status
                }))
                if loginStatus == .requiresApproval {
                    Button(L("Autoriser dans les Réglages Système…")) { SMAppService.openSystemSettingsLoginItems() }
                }
                if !AppInstallation.isInApplications(Bundle.main.bundleURL) {
                    Text(L("Placez l’app dans /Applications pour le lancement automatique.")).font(.caption).foregroundStyle(.secondary)
                }
                Picker(L("Langue"), selection: $store.settings.language) {
                    ForEach(AppLanguage.allCases, id: \.rawValue) { language in
                        Text(language.nativeName).tag(language.rawValue)
                    }
                }
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            }
        }.formStyle(.grouped).onAppear { loginStatus = SMAppService.mainApp.status }
    }
}
struct AccountsTab: View {
    @Bindable var store: UsageStore
    @State private var selection: UUID?
    @State private var editing: Account?
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            List(selection: $selection) {
                ForEach(store.accounts) { account in
                    HStack {
                        Toggle("", isOn: Binding(get: { store.accounts.first { $0.id == account.id }?.enabled ?? false }, set: { enabled in var copy = account; copy.enabled = enabled; store.update(copy) }))
                            .toggleStyle(.checkbox).labelsHidden()
                        Image(systemName: account.provider.symbol).frame(width: 22)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(account.displayName).fontWeight(.medium)
                            Text(store.states[account.id]?.usage?.identity?.email ?? account.configPath).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        Text(store.states[account.id]?.message ?? L("Connecté")).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }.padding(.vertical, 5).tag(account.id)
                        .contextMenu { Button(L("Modifier…")) { editing = account }; Button(L("Supprimer")) { store.remove(account.id) } }
                }.onMove { source, destination in store.accounts.move(fromOffsets: source, toOffset: destination); store.saveAccounts() }
            }.border(.quaternary)
            HStack {
                Menu {
                    ForEach(Provider.allCases, id: \.self) { provider in
                        Button(provider.title) {
                            var account = Account(provider: provider, label: L("Perso"))
                            if provider.supportsConfigDirectory && store.accounts.contains(where: { $0.provider == provider && $0.configDirMode == .cliDefault }) {
                                account.configDirMode = .dedicated
                                account.configDir = store.paths.file("accounts/\(account.id)/\(provider.rawValue)")
                            }
                            editing = account
                        }.disabled(!provider.supportsConfigDirectory && store.accounts.contains { $0.provider == provider })
                    }
                } label: { Image(systemName: "plus") }.frame(width: 42).help(L("Ajouter un compte"))
                Button { if let selection { store.remove(selection); self.selection = nil } } label: { Image(systemName: "minus") }.disabled(selection == nil)
                Spacer()
                Button(L("Modifier…")) { editing = store.accounts.first { $0.id == selection } }.disabled(selection == nil)
            }
            Text(L("Supprimer un compte du widget conserve sa session CLI et son dossier.")).font(.caption).foregroundStyle(.secondary)
        }.sheet(item: $editing) { account in AccountEditor(store: store, account: account) }
    }
}
struct AccountEditor: View {
    var store: UsageStore
    @State var account: Account
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    @State private var services: [KeychainReader.Service] = []
    @State private var credentialInfo: String?
    @State private var working = false
    private var saved: Bool { store.accounts.contains { $0.id == account.id } }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(account.provider.title + " — " + L("Compte")).font(.title2.weight(.semibold))
            Form {
                TextField(L("Nom du compte"), text: $account.label, prompt: Text("Playlounge, IC…"))
                Text(account.displayName).font(.caption).foregroundStyle(.secondary)
                Picker(L("Dossier de configuration"), selection: $account.configDirMode) {
                    if !store.accounts.contains(where: { $0.id != account.id && $0.provider == account.provider && $0.configDirMode == .cliDefault }) {
                        Text(L("Session CLI par défaut")).tag(ConfigDirMode.cliDefault)
                    }
                    if account.provider.supportsConfigDirectory {
                        Text(L("Dossier dédié au widget")).tag(ConfigDirMode.dedicated)
                        Text(L("Dossier existant")).tag(ConfigDirMode.custom)
                    }
                }.disabled(saved)
                if account.configDirMode != .cliDefault {
                    HStack {
                        Text(account.configDir?.path ?? L("Choisissez un dossier")).font(.caption).textSelection(.enabled).lineLimit(2)
                        if account.configDirMode == .custom && !saved { Button(L("Choisir…")) { chooseDirectory() } }
                    }
                }
            }
            if account.provider == .cursor {
                Toggle(L("Autoriser les quotas Cursor via la session web"), isOn: Binding(get: { account.cursorWebUsageEnabled == true }, set: { account.cursorWebUsageEnabled = $0 }))
                Text(L("Utilise le jeton du CLI pour lire les quotas sur cursor.com. Désactivé par défaut.")).font(.caption).foregroundStyle(.secondary)
            }
            if account.provider.experimental { Text(L("Support expérimental — session CLI par défaut uniquement.")).font(.caption).foregroundStyle(.secondary) }
            if saved { AccountSection(store: store, account: store.accounts.first { $0.id == account.id } ?? account) }
            if account.provider == .claude {
                DisclosureGroup(L("Service trousseau (repli manuel)")) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(account.keychainService).font(.caption.monospaced()).textSelection(.enabled)
                        Button(L("Lister les services")) { Task {
                            do { services = try await KeychainReader().services() } catch { self.error = L("Impossible de lire les services du trousseau") }
                        } }
                        if !services.isEmpty {
                            Picker(L("Service"), selection: Binding(get: { account.keychainServiceOverride ?? "" }, set: { value in
                                account.keychainServiceOverride = value.isEmpty ? nil : value
                                Task { await inspectCredential() }
                            })) {
                                Text(L("Automatique")).tag("")
                                ForEach(services) { service in Text(service.name + (service.modified.map { " · " + $0.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(appLocale())) } ?? "")).tag(service.name) }
                            }
                        }
                        if let credentialInfo { Text(credentialInfo).font(.caption).foregroundStyle(.secondary) }
                    }.padding(.top, 6)
                }
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button(L("Se connecter…")) { Task { if save() { working = true; await store.login(account); working = false } } }
                Button(L("Vérifier")) { Task { if save() { working = true; await store.refresh(.account, only: account.id); working = false } } }
                Button(L("Copier la commande")) { Task {
                    guard let binary = await BinaryLocator().locate(account.provider, override: store.settings.binaryOverride(account.provider)) else { error = L("CLI introuvable"); return }
                    if account.configDirMode != .cliDefault && account.configDir == nil { error = L("Choisissez un dossier"); return }
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(LoginCommand.shell(account: account, binary: binary), forType: .string)
                } }
            }.disabled(working)
            HStack {
                Button(L("Fermer")) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(L("Enregistrer")) { if save() { dismiss() } }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 530)
        .onChange(of: account.configDirMode) { _, mode in
            account.configDir = mode == .dedicated ? store.paths.file("accounts/\(account.id)/\(account.provider.rawValue)") : nil
        }
    }
    private func save() -> Bool {
        account.label = account.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !account.label.isEmpty else { error = L("Saisissez un nom de compte"); return false }
        do {
            try store.paths.validate(account, among: store.accounts)
            if var current = store.accounts.first(where: { $0.id == account.id }) {
                current.label = account.label
                if current == account {
                    if !store.rename(account.id, to: account.label) { error = ErrorKind.storage.message; return false }
                } else { store.update(account) }
            } else { try store.add(account) }
            return true
        } catch { self.error = ErrorKind.invalidConfig.message; return false }
    }
    private func chooseDirectory() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK { account.configDir = panel.url?.standardizedFileURL }
    }
    private func inspectCredential() async {
        do {
            let credential = try await KeychainReader().read(account: account)
            credentialInfo = [credential.subscriptionType, credential.rateLimitTier, L("Expiration") + " : " + credential.expires.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(appLocale()))].compactMap { $0 }.joined(separator: " · ")
        } catch { credentialInfo = (error as? ErrorKind ?? .process).message }
    }
}
struct AdvancedTab: View {
    @Bindable var store: UsageStore
    var body: some View {
        Form {
            Section(L("CLIs")) {
                ForEach(Provider.allCases, id: \.self) { provider in
                    HStack {
                        TextField(provider.title, text: Binding(get: { store.settings.binaryOverride(provider) ?? "" }, set: { value in
                            if provider == .claude { store.settings.claudeBinary = value }
                            else if provider == .codex { store.settings.codexBinary = value }
                            else { var paths = store.settings.additionalBinaries ?? [:]; paths[provider.rawValue] = value; store.settings.additionalBinaries = paths }
                        }), prompt: Text(store.binaryPaths[provider] ?? L("Détection automatique")))
                        if let version = store.versions[provider] { Text(version).font(.caption.monospaced()).foregroundStyle(.secondary) }
                    }
                }
                Button(L("Détecter les binaires")) { Task { await store.detectBinaries() } }
            }
            Section(L("Sources supplémentaires")) {
                Toggle(L("Crédits supplémentaires Claude"), isOn: $store.settings.extraUsage)
                ForEach(store.accounts.filter { $0.provider == .claude }) { account in
                    Toggle(L("Statusline Claude") + " · " + account.label, isOn: Binding(get: { account.statuslineEnabled == true }, set: { store.toggleStatusline(account, enabled: $0) }))
                }
                Text(L("La statusline existante est conservée et chaînée. Désactiver restaure la configuration précédente.")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L("Diagnostic")) {
                Button(L("Ouvrir les logs dans Console")) { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app")) }
                Text("subsystem:com.jbd.AIUsage").font(.caption.monospaced()).textSelection(.enabled)
                Button(L("Exporter un diagnostic…")) { store.exportDiagnostic() }
                Button(L("Réinitialiser le cache")) { store.clearCache() }
                Button(L("Ouvrir le dossier de l’app")) { NSWorkspace.shared.open(store.paths.root) }
            }
            if let error = store.storageError { Text(error).font(.caption).foregroundStyle(.red) }
        }.formStyle(.grouped)
    }
}
