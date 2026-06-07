// SaveVisionUserApp.swift
// Entry point for the SaveVision user app (the glasses wearer's companion app).
//
// Role in the system: capture the wearer's POV (from Ray-Ban Display glasses via
// the Meta Wearables Device Access Toolkit, or the iPhone camera as a fallback)
// and publish it over WebRTC to the operator. Receive guidance text back over a
// data channel and render it on the glasses display.

import SwiftUI

@main
struct SaveVisionUserApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
