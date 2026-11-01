//
//  leanring_buddyTests.swift
//  leanring-buddyTests
//
//  Created by thorfinn on 3/2/26.
//

import Testing
@testable import leanring_buddy

struct leanring_buddyTests {

    @Test func firstPermissionRequestUsesSystemPromptOnly() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: false
        )

        #expect(presentationDestination == .systemPrompt)
    }

    @Test func repeatedPermissionRequestOpensSystemSettings() async throws {
        let presentationDestination = WindowPositionManager.permissionRequestPresentationDestination(
            hasPermissionNow: false,
            hasAttemptedSystemPrompt: true
        )

        #expect(presentationDestination == .systemSettings)
    }

    @Test func knownGrantedScreenRecordingPermissionSkipsTheGate() async throws {
        let shouldTreatPermissionAsGranted = WindowPositionManager.shouldTreatScreenRecordingPermissionAsGrantedForSessionLaunch(
            hasScreenRecordingPermissionNow: false,
            hasPreviouslyConfirmedScreenRecordingPermission: true
        )

        #expect(shouldTreatPermissionAsGranted)
    }

    @Test func compactGuidanceJSONParsesSpeechAndVisualActions() async throws {
        let response = #"{"s":[{"t":"open settings","p":{"x":120,"y":240,"l":"settings","n":2},"d":[{"k":"c","v":[120,240,30],"l":"settings","n":2}]}]}"#
        let steps = GuidanceParser.parse(response)

        #expect(steps.count == 1)
        #expect(steps[0].spokenText == "open settings")
        #expect(steps[0].point?.coordinate == CGPoint(x: 120, y: 240))
        #expect(steps[0].point?.screenNumber == 2)
        #expect(steps[0].drawings.count == 1)
        #expect(steps[0].drawings[0].kind == .circle)
    }

    @Test func compactGuidanceJSONSurvivesAChattyPrefix() async throws {
        let response = #"here is the structured answer: {"s":[{"t":"look at the top bar"}]}"#
        let steps = GuidanceParser.parse(response)

        #expect(steps.count == 1)
        #expect(steps[0].spokenText == "look at the top bar")
    }

    @Test func legacyGuidanceTagsStillParse() async throws {
        let steps = GuidanceParser.parse("click the export button. [POINT:500,200:export]")

        #expect(steps.count == 1)
        #expect(steps[0].spokenText == "click the export button.")
        #expect(steps[0].point?.label == "export")
    }

}
