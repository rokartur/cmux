@testable import CmuxNextApp
import CmuxNextCloud
import Testing

@Suite("Cloud workspace setup")
struct CloudWorkspaceSetupWizardTests {
    @Test func emptyVMStartsWithoutRepositoryEvenWhenTheFieldHasStaleText() throws {
        let plan = try CloudWorkspaceSetupWizard.Plan.make(source: .empty, repositoryText: "not a repository")

        #expect(plan.source == .empty)
        #expect(plan.repository == nil)
        #expect(plan.request.isDefault)
    }

    @Test func repositoryChoiceBuildsACloneRequestForTheSelectedRef() throws {
        let plan = try CloudWorkspaceSetupWizard.Plan.make(source: .repository,
                                                           repositoryText: "https://github.com/octo/paint/tree/fix/brush")

        #expect(plan.source == .repository)
        #expect(plan.repository?.spec == "octo/paint@fix/brush")
        #expect(plan.request.repo == plan.repository)
        #expect(!plan.request.isDefault)
    }

    @Test func repositoryChoiceRejectsCredentialsEmbeddedInTheURL() {
        #expect(throws: CloudMachineRepo.Invalid.credentialsInURL) {
            try CloudWorkspaceSetupWizard.Plan.make(source: .repository,
                                                   repositoryText: "https://user:secret@github.com/octo/paint")
        }
    }

    @Test(arguments: [
        (nil, true, CloudWorkspaceSetupWizard.CredentialAvailability.available),
        ("team-1", true, .teamMachine),
        (nil, false, .unsupportedCloudRoute),
    ])
    func providerSetupAvailabilityFollowsAccountScopeAndFileRoute(
        teamID: String?, supportsFileRoute: Bool, expected: CloudWorkspaceSetupWizard.CredentialAvailability
    ) {
        #expect(CloudWorkspaceSetupWizard.CredentialAvailability.resolve(teamID: teamID, supportsFileRoute: supportsFileRoute) == expected)
    }
}
