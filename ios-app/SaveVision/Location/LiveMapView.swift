import CoreLocation
import SwiftUI

/// Live map: continuously tracks the wearer's GPS position and renders it on the
/// OpenStreetMap view, recentering and rotating to heading as they move. Reuses
/// `LocationManager` (CoreLocation) + `OSMMapView`.
struct LiveMapView: View {
    @StateObject private var location = LocationManager()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if let fix = location.current {
                    OSMMapView(
                        coordinate: GeoCoordinate(
                            latitude: fix.coordinate.latitude,
                            longitude: fix.coordinate.longitude
                        ),
                        bearing: fix.course >= 0 ? fix.course : nil
                    )
                    .ignoresSafeArea()
                } else if location.authorization == .denied || location.authorization == .restricted {
                    ContentUnavailableView(
                        "Location access needed",
                        systemImage: "location.slash",
                        description: Text("Enable location for SaveVision in Settings to use the live map.")
                    )
                } else {
                    VStack(spacing: 12) {
                        ProgressView().controlSize(.large)
                        Text("Waiting for GPS fix…").foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Live Map")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay(alignment: .bottom) {
                if let fix = location.current {
                    Text(GeoCoordinate(
                        latitude: fix.coordinate.latitude,
                        longitude: fix.coordinate.longitude
                    ).shortText)
                    .font(.caption.monospaced())
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .textSelection(.enabled)
                }
            }
        }
        .onAppear { location.start() }
        .onDisappear { location.stop() }
    }
}
