import AppKit
import CmuxNextActions
import CmuxNextCloud
import CmuxNextDesign
import CmuxNextDaemon

/// The short, person-started setup behind New Cloud Machine. The existing
/// creation flow still owns provisioning and opening the first workspace.
@MainActor
struct CloudWorkspaceSetupWizard {
    let context: AppActionContext

    nonisolated enum Source: String, Sendable, Equatable {
        case empty
        case repository
    }

    nonisolated struct Plan: Sendable, Equatable {
        var source: Source
        var repository: CloudMachineRepo?

        var request: CloudMachineRequest { CloudMachineRequest(repo: repository) }

        static func make(source: Source, repositoryText: String) throws -> Plan {
            switch source {
            case .empty:
                return Plan(source: .empty, repository: nil)
            case .repository:
                return Plan(source: .repository, repository: try CloudMachineRepo.parse(repositoryText))
            }
        }
    }

    nonisolated enum CredentialAvailability: Equatable, Sendable {
        case available
        case teamMachine
        case unsupportedCloudRoute

        static func resolve(teamID: String?, supportsFileRoute: Bool) -> CredentialAvailability {
            guard teamID == nil else { return .teamMachine }
            return supportsFileRoute ? .available : .unsupportedCloudRoute
        }
    }

    private enum Field {
        static let source = "source"
        static let repository = "repository"
    }

    func begin(window: WindowState?, askedBy: String? = nil) {
        CloudHandlers.runTracked("new Cloud workspace", context) { [context] in
            guard let plan = await Self.choosePlan(context: context) else { return }
            let creation = CloudHandlers.creationFlow(context, startedByPerson: true, askedBy: askedBy)
                .start(in: window, existing: nil, request: plan.request)
            guard case .created? = await CloudHandlers.settledCreation(creation, in: context.services.cloud.creations),
                  let session = creation.session,
                  await Self.waitUntilReady(creation) else { return }
            await Self.offerCredentialSetup(for: session, context: context)
        }
    }

    private static func choosePlan(context: AppActionContext) async -> Plan? {
        let cloud = context.services.cloud
        let supportsFileRoute = cloud.configuration.linkSource == .legacy
        let availability = CredentialAvailability.resolve(teamID: cloud.auth.teamID, supportsFileRoute: supportsFileRoute)
        let lines = [Strings.setupSummary, Strings.credentialsNote(availability)]
        let spec = CmuxDialogSpec(
            title: Strings.title,
            lines: lines,
            fields: [
                .choice(id: Field.source, label: Strings.sourceLabel,
                        options: [
                            CmuxDialogOption(label: Strings.emptyChoice, value: Source.empty.rawValue),
                            CmuxDialogOption(label: Strings.repositoryChoice, value: Source.repository.rawValue),
                        ], selected: Source.empty.rawValue),
                .text(Field.repository, initial: "", label: Strings.repositoryLabel,
                      placeholder: Strings.repositoryPlaceholder),
            ],
            buttons: [
                .cancel(Strings.cancel),
                CmuxDialogButton(id: "create", title: Strings.create, role: .default),
            ],
            identifier: "cmux.dialog.cloud.workspaceSetup")
        let answer = await CmuxDialogCenter.shared.present(spec, in: scope(context))
        guard answer.button == "create", !answer.isDismissal,
              let choice = answer.text(Field.source),
              let source = Source(rawValue: choice) else { return nil }
        do {
            if source == .empty { return try Plan.make(source: .empty, repositoryText: "") }
            return try Plan.make(source: source, repositoryText: answer.text(Field.repository) ?? "")
        } catch let error as CloudMachineRepo.Invalid {
            let detail: String
            switch error {
            case .unrecognized: detail = Strings.repositoryInvalid
            case .credentialsInURL: detail = Strings.repositoryCredentials
            case .invalidRef: detail = Strings.repositoryRefInvalid
            }
            CloudPresenter.failure(ActionFailure(message: detail), in: context.services.windows.active?.window)
            return nil
        } catch {
            CloudPresenter.failure(error, in: context.services.windows.active?.window)
            return nil
        }
    }

    private static func offerCredentialSetup(for session: CloudMachineSession, context: AppActionContext) async {
        let services = context.services
        let cloud = context.services.cloud
        let teamID = cloud.auth.teamID
        let userID = cloud.auth.user?.id
        let availability = CredentialAvailability.resolve(
            teamID: teamID,
            supportsFileRoute: cloud.configuration.linkSource == .legacy)
        guard availability == .available, let userID else { return }

        let spec = CmuxDialogSpec(
            title: Strings.credentialTitle(session.machine.title),
            lines: [Strings.credentialDisclosure(session.machine.title, cloud.auth.activeTeam.team?.displayName ?? Strings.personalAccount)],
            fields: [
                .check(id: "claude", title: Strings.setupClaude, on: false),
                .check(id: "codex", title: Strings.setupCodex, on: false),
            ],
            buttons: [
                CmuxDialogButton(id: "skip", title: Strings.skip, role: .default),
                CmuxDialogButton(id: "transfer", title: Strings.transferAndFinish, role: .normal),
            ],
            identifier: "cmux.dialog.cloud.workspaceCredentials")
        let answer = await CmuxDialogCenter.shared.present(spec, in: scope(context))
        guard answer.button == "transfer", !answer.isDismissal else { return }

        do {
            if answer.isOn("claude") {
                let transfer = CloudCredentialTransfer(provider: .claude, machineID: session.machineID, teamID: teamID,
                                                       userID: userID, openTerminal: { [weak services] line in
                    services?.inFrontPane { $0.newTerminalTab(typing: line + "\r") } ?? false
                })
                try await transfer.run(api: cloud.api, currentTeamID: { cloud.auth.teamID },
                                       currentUserID: { cloud.auth.user?.id }, confirmed: true)
            }
            if answer.isOn("codex") {
                let transfer = CloudCredentialTransfer(provider: .codex, machineID: session.machineID, teamID: teamID,
                                                       userID: userID, openTerminal: { [weak services] line in
                    services?.inFrontPane { $0.newTerminalTab(typing: line + "\r") } ?? false
                })
                try await transfer.run(api: cloud.api, currentTeamID: { cloud.auth.teamID },
                                       currentUserID: { cloud.auth.user?.id }, confirmed: true)
            }
        } catch let failure as CloudCredentialTransfer.Failure {
            CloudPresenter.show(Strings.credentialFailedTitle, Strings.credentialFailure(failure), in: context.services.windows.active?.window)
        } catch {
            CloudPresenter.show(Strings.credentialFailedTitle, Strings.credentialFailed, in: context.services.windows.active?.window)
        }
    }

    private static func waitUntilReady(_ creation: CloudMachineCreation) async -> Bool {
        for await stage in ObservationStream({ creation.stage }) {
            if stage == .ready { return true }
            if stage.isFinished { return false }
        }
        return false
    }

    private static func scope(_ context: AppActionContext) -> CmuxDialogScope {
        if let window = context.services.windows.active?.window { return .window(window) }
        return .app
    }
}

private enum Strings {
    static let title = String(localized: "cloud.workspaceSetup.title", defaultValue: "New Cloud Workspace", table: "Cloud", bundle: .module)
    static let setupSummary = String(localized: "cloud.workspaceSetup.summary", defaultValue: "Choose a starting point. A repository is cloned into ~/work on the new VM; no credential is stored in the repository URL.", table: "Cloud", bundle: .module)
    static let sourceLabel = String(localized: "cloud.workspaceSetup.sourceLabel", defaultValue: "Start with", table: "Cloud", bundle: .module)
    static let emptyChoice = String(localized: "cloud.workspaceSetup.emptyChoice", defaultValue: "Empty VM — start a new project", table: "Cloud", bundle: .module)
    static let repositoryChoice = String(localized: "cloud.workspaceSetup.repositoryChoice", defaultValue: "From repository", table: "Cloud", bundle: .module)
    static let repositoryLabel = String(localized: "cloud.workspaceSetup.repositoryLabel", defaultValue: "GitHub repository (only for From repository)", table: "Cloud", bundle: .module)
    static let repositoryPlaceholder = String(localized: "cloud.workspaceSetup.repositoryPlaceholder", defaultValue: "owner/repository or GitHub URL", table: "Cloud", bundle: .module)
    static let create = String(localized: "cloud.workspaceSetup.create", defaultValue: "Create workspace", table: "Cloud", bundle: .module)
    static let cancel = String(localized: "cloud.workspaceSetup.cancel", defaultValue: "Cancel", table: "Cloud", bundle: .module)
    static let repositoryInvalid = String(localized: "cloud.workspaceSetup.repositoryInvalid", defaultValue: "Enter a GitHub repository as owner/name or a GitHub URL.", table: "Cloud", bundle: .module)
    static let repositoryCredentials = String(localized: "cloud.workspaceSetup.repositoryCredentials", defaultValue: "Remove the username or password from the repository URL. cmux never saves URL credentials on the VM.", table: "Cloud", bundle: .module)
    static let repositoryRefInvalid = String(localized: "cloud.workspaceSetup.repositoryRefInvalid", defaultValue: "The branch, tag, or commit name is not supported.", table: "Cloud", bundle: .module)
    static let skip = String(localized: "cloud.workspaceSetup.skip", defaultValue: "Skip", table: "Cloud", bundle: .module)
    static let setupClaude = String(localized: "cloud.workspaceSetup.setupClaude", defaultValue: "Claude", table: "Cloud", bundle: .module)
    static let setupCodex = String(localized: "cloud.workspaceSetup.setupCodex", defaultValue: "Codex", table: "Cloud", bundle: .module)
    static let transferAndFinish = String(localized: "cloud.workspaceSetup.transferAndFinish", defaultValue: "Transfer and finish", table: "Cloud", bundle: .module)
    static let credentialFailedTitle = String(localized: "cloud.workspaceSetup.credentialFailedTitle", defaultValue: "Provider setup stopped", table: "Cloud", bundle: .module)
    static let credentialFailed = String(localized: "cloud.workspaceSetup.credentialFailed", defaultValue: "cmux could not finish setting up the provider. No credential details were shown.", table: "Cloud", bundle: .module)
    static let personalAccount = String(localized: "cloud.workspaceSetup.personalAccount", defaultValue: "Personal account", table: "Cloud", bundle: .module)

    static func credentialsNote(_ availability: CloudWorkspaceSetupWizard.CredentialAvailability) -> String {
        switch availability {
        case .available:
            String(localized: "cloud.workspaceSetup.credentialsAvailable", defaultValue: "Optional Claude or Codex setup happens after the VM starts and requires a separate confirmation.", table: "Cloud", bundle: .module)
        case .teamMachine:
            String(localized: "cloud.workspaceSetup.credentialsTeamUnavailable", defaultValue: "Personal provider credentials stay off shared team VMs because they share a home folder.", table: "Cloud", bundle: .module)
        case .unsupportedCloudRoute:
            String(localized: "cloud.workspaceSetup.credentialsRouteUnavailable", defaultValue: "Provider credential setup is unavailable with this Cloud connection.", table: "Cloud", bundle: .module)
        }
    }

    static func credentialTitle(_ machine: String) -> String {
        String(format: String(localized: "cloud.workspaceSetup.credentialTitle", defaultValue: "Set up an AI provider on %@?", table: "Cloud", bundle: .module), machine)
    }

    static func credentialDisclosure(_ machine: String, _ team: String) -> String {
        String(format: String(localized: "cloud.workspaceSetup.credentialDisclosure", defaultValue: "Claude reuses its saved setup token. Codex starts a fresh login for this VM in a visible terminal on this Mac. The selected credential is installed on %@ for %@, replacing that provider's login for future launches. Existing sessions stay unchanged. Select one or both providers, then confirm the transfer.", table: "Cloud", bundle: .module), machine, team)
    }

    static func credentialFailure(_ failure: CloudCredentialTransfer.Failure) -> String {
        switch failure {
        case .sharedMachine:
            String(localized: "cloud.workspaceSetup.sharedMachine", defaultValue: "This VM is shared by a team, so personal provider credentials were not moved.", table: "Cloud", bundle: .module)
        case .scopeChanged:
            String(localized: "cloud.workspaceSetup.scopeChanged", defaultValue: "Your cmux account or team changed. Start provider setup again from the same account.", table: "Cloud", bundle: .module)
        default:
            credentialFailed
        }
    }
}
