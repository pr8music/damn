//
//  ClickyAnalytics.swift
//  leanring-buddy
//
//  FREE/PRIVATE SETUP: the original file sent usage events, including your
//  spoken transcripts and Clicky's replies, to the author's PostHog account.
//  This version keeps the same function names so the rest of the app still
//  compiles, but every function does nothing. Nothing leaves your Mac here.
//

import Foundation

enum ClickyAnalytics {
    static func configure() {}
    static func trackAppOpened() {}
    static func trackOnboardingStarted() {}
    static func trackOnboardingReplayed() {}
    static func trackOnboardingVideoCompleted() {}
    static func trackOnboardingDemoTriggered() {}
    static func trackAllPermissionsGranted() {}
    static func trackPermissionGranted(permission: String) {}
    static func trackPushToTalkStarted() {}
    static func trackPushToTalkReleased() {}
    static func trackUserMessageSent(transcript: String) {}
    static func trackAIResponseReceived(response: String) {}
    static func trackElementPointed(elementLabel: String?) {}
    static func trackResponseError(error: String) {}
    static func trackTTSError(error: String) {}
}
