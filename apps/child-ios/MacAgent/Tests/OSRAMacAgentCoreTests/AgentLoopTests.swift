import XCTest
import FamilyShieldAgent
@testable import OSRAMacAgentCore

/// The daemon's cycle with every dependency faked: what it sends, when, and what it never does.
final class AgentLoopTests: XCTestCase {

    /// Records what the loop asked for, and answers as each test sets it up.
    private final class World {
        var identity: AgentIdentity?
        var proof: SecretProof.Outcome = .accepted
        var drain = AgentLoop.Drain()
        var sync: AgentLoop.Sync = .synced(version: 3)
        var heartbeatStatus = 202
        var childAccount: ChildAccount.Kind?
        var calls: [String] = []
        var lines: [String] = []

        var dependencies: AgentLoop.Dependencies {
            AgentLoop.Dependencies(
                loadIdentity: { self.identity },
                prove: { _ in self.calls.append("prove"); return self.proof },
                drain: {
                    self.calls.append("drain")
                    // The shared code clears the pairing when the server says device_revoked.
                    if self.drain.revoked { self.identity = nil }
                    return self.drain
                },
                syncRules: { self.calls.append("sync"); return self.sync },
                heartbeat: { _ in self.calls.append("heartbeat"); return self.heartbeatStatus },
                childAccount: { self.childAccount },
                log: { self.lines.append($0) }
            )
        }
    }

    private static let markers = ["TOKEN-MARKER", "DEVICE-MARKER", "CHILD-MARKER", "FAMILY-MARKER", "SECRET-MARKER",
                                  "NAME-MARKER"]

    private func identity(device: String = "DEVICE-MARKER") -> AgentIdentity {
        AgentIdentity(apiBaseURL: MacAgentServer.builtIn, deviceToken: "TOKEN-MARKER", deviceId: device,
                      childId: "CHILD-MARKER", familyId: "FAMILY-MARKER", hmacSecret: "SECRET-MARKER",
                      childName: "NAME-MARKER")
    }

    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    // Mutant: draining, syncing or sending a heartbeat with no pairing stored.
    func testAnUnpairedMacSendsNothingAndLooksAgainSoon() async {
        let world = World()
        let loop = AgentLoop(world.dependencies)
        let wait = await loop.tick(now: start)
        XCTAssertEqual(world.calls, [])
        XCTAssertEqual(loop.state, .notPaired)
        XCTAssertEqual(wait, AgentLoop.Cadence.unpaired)
        XCTAssertEqual(world.lines, ["state=not_paired"])
    }

    // Mutant: sending the heartbeat or the poll before the proof, or skipping the proof.
    func testTheFirstCycleProvesTheSecretThenPollsSyncsAndReports() async {
        let world = World()
        world.identity = identity()
        let loop = AgentLoop(world.dependencies)
        let wait = await loop.tick(now: start)
        XCTAssertEqual(world.calls, ["prove", "drain", "sync", "heartbeat"])
        XCTAssertEqual(loop.state, .paired)
        XCTAssertEqual(wait, AgentLoop.Cadence.poll)
        XCTAssertEqual(world.lines, ["state=paired", "event=heartbeat status=202"])
    }

    // #775's planted fault: a wrong HMAC key. Mutant: treating a refused proof as paired, or going on to the poll
    // and the heartbeat (which use the device token and would still be accepted by the server).
    func testARefusedSecretIsNeverPairedAndNothingIsSentAsTheDevice() async {
        let world = World()
        world.identity = identity()
        world.proof = .refused("invalid_signature")
        let loop = AgentLoop(world.dependencies)
        let wait = await loop.tick(now: start)
        _ = await loop.tick(now: start.addingTimeInterval(AgentLoop.Cadence.refused))
        XCTAssertEqual(world.calls, ["prove", "prove"], "asked again later, and nothing else was sent")
        XCTAssertEqual(loop.state, .secretRefused)
        XCTAssertEqual(wait, AgentLoop.Cadence.refused)
        XCTAssertEqual(world.lines, ["state=secret_refused reason=invalid_signature"])
        XCTAssertFalse(world.lines.contains { $0.contains("state=paired") })
    }

    // Mutant: counting "no verdict" (offline, a server fault, a clock five minutes off) as accepted.
    func testNoVerdictIsNotPairedAndIsAskedAgainOnTheNextCycle() async {
        let world = World()
        world.identity = identity()
        let loop = AgentLoop(world.dependencies)
        world.proof = .inconclusive(0)
        _ = await loop.tick(now: start)
        XCTAssertEqual(loop.state, .unverified)
        world.proof = .clockSkew
        _ = await loop.tick(now: start.addingTimeInterval(60))
        XCTAssertEqual(loop.state, .unverified)
        XCTAssertEqual(world.calls, ["prove", "prove"])
        world.proof = .accepted
        _ = await loop.tick(now: start.addingTimeInterval(120))
        XCTAssertEqual(loop.state, .paired)
        XCTAssertEqual(world.lines.prefix(3), ["state=unverified status=0", "state=unverified reason=clock_skew", "state=paired"])
    }

    // Mutant: a heartbeat or a full rule sync on every 60-second cycle, or the proof repeated every cycle.
    func testBetweenHeartbeatsACycleIsOnePoll() async {
        let world = World()
        world.identity = identity()
        let loop = AgentLoop(world.dependencies)
        _ = await loop.tick(now: start)
        world.calls = []
        _ = await loop.tick(now: start.addingTimeInterval(60))
        _ = await loop.tick(now: start.addingTimeInterval(AgentLoop.Cadence.heartbeat - 1))
        XCTAssertEqual(world.calls, ["drain", "drain"])
        _ = await loop.tick(now: start.addingTimeInterval(AgentLoop.Cadence.heartbeat))
        XCTAssertEqual(world.calls, ["drain", "drain", "drain", "sync", "heartbeat"])
    }

    // Mutant: recording a heartbeat the server never stored, so an offline Mac stays silent for 15 minutes.
    func testAHeartbeatThatDidNotArriveIsSentAgainOnTheNextCycle() async {
        let world = World()
        world.identity = identity()
        world.heartbeatStatus = 0
        world.sync = .failed
        let loop = AgentLoop(world.dependencies)
        _ = await loop.tick(now: start)
        world.calls = []
        world.heartbeatStatus = 202
        world.sync = .synced(version: 4)
        _ = await loop.tick(now: start.addingTimeInterval(60))
        XCTAssertEqual(world.calls, ["drain", "sync", "heartbeat"])
    }

    // Mutant: carrying on (heartbeat, sync) after the parent removed this Mac.
    func testRemovedByTheParentStopsTheCycleAndANewPairingIsProvenAgain() async {
        let world = World()
        world.identity = identity()
        let loop = AgentLoop(world.dependencies)
        _ = await loop.tick(now: start)
        world.calls = []
        world.drain = AgentLoop.Drain(revoked: true)
        let wait = await loop.tick(now: start.addingTimeInterval(60))
        XCTAssertEqual(world.calls, ["drain"])
        XCTAssertEqual(loop.state, .notPaired)
        XCTAssertEqual(wait, AgentLoop.Cadence.unpaired)

        world.calls = []
        world.drain = AgentLoop.Drain()
        world.identity = identity(device: "ANOTHER-DEVICE")
        _ = await loop.tick(now: start.addingTimeInterval(70))
        XCTAssertEqual(world.calls, ["prove", "drain", "sync", "heartbeat"], "a new pairing starts from the proof")
    }

    // Mutant: a rule sync that finds the device removed (the shared syncer unpairs) still sending the heartbeat.
    func testASyncThatFindsNoPairingEndsTheCycle() async {
        let world = World()
        world.identity = identity()
        world.sync = .notPaired
        let loop = AgentLoop(world.dependencies)
        _ = await loop.tick(now: start)
        XCTAssertEqual(world.calls, ["prove", "drain", "sync"])
        XCTAssertEqual(loop.state, .notPaired)
    }

    // 428: consent withdrawn. The server keeps answering it, so it is not asked every minute.
    func testConsentWithdrawnIsNotHammered() async {
        let world = World()
        world.identity = identity()
        world.sync = .consentWithdrawn
        world.heartbeatStatus = 428
        let loop = AgentLoop(world.dependencies)
        _ = await loop.tick(now: start)
        world.calls = []
        _ = await loop.tick(now: start.addingTimeInterval(60))
        XCTAssertEqual(world.calls, ["drain"])
    }

    // #775: "No PII and no secrets in the log." Mutant: any line that interpolates the identity.
    func testNoLogLineCarriesAnythingFromTheIdentity() async {
        let world = World()
        world.identity = identity()
        world.childAccount = .administrator
        world.drain = AgentLoop.Drain(handled: 2, refused: 1)
        let loop = AgentLoop(world.dependencies)
        _ = await loop.tick(now: start)
        world.proof = .refused("invalid_signature")
        world.identity = identity(device: "DEVICE-MARKER-2")
        _ = await loop.tick(now: start.addingTimeInterval(60))
        XCTAssertEqual(world.lines, [
            "state=paired",
            "child_account=administrator",
            "event=commands handled=2 refused=1",
            "event=heartbeat status=202",
            "state=secret_refused reason=invalid_signature",
        ])
        for line in world.lines {
            for marker in Self.markers { XCTAssertFalse(line.contains(marker), "\(marker) reached the log: \(line)") }
        }
    }
}
