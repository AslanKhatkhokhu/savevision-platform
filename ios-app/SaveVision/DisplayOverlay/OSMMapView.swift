import MapKit
import SwiftUI

/// A non-interactive OpenStreetMap view centered on an operator-supplied
/// coordinate. Uses an `MKTileOverlay` against the public OSM tile server so the
/// base map is OpenStreetMap (not Apple Maps). Rendered semi-transparently by the
/// overlay so the live point-of-view stays visible underneath.
struct OSMMapView: UIViewRepresentable {
    let coordinate: GeoCoordinate
    /// Optional heading (degrees) used to rotate the map toward a direction.
    var bearing: Double?
    /// Span in degrees — smaller is more zoomed in.
    var span: CLLocationDegrees = 0.008

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.isUserInteractionEnabled = false
        map.showsUserLocation = false
        map.isRotateEnabled = false
        map.pointOfInterestFilter = .excludingAll

        let overlay = MKTileOverlay(urlTemplate: "https://tile.openstreetmap.org/{z}/{x}/{y}.png")
        overlay.canReplaceMapContent = true // replace Apple's base map with OSM tiles
        overlay.maximumZ = 19
        map.addOverlay(overlay, level: .aboveLabels)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let center = CLLocationCoordinate2D(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let region = MKCoordinateRegion(
            center: center,
            span: MKCoordinateSpan(latitudeDelta: span, longitudeDelta: span)
        )
        map.setRegion(region, animated: false)

        map.removeAnnotations(map.annotations)
        let pin = MKPointAnnotation()
        pin.coordinate = center
        map.addAnnotation(pin)

        if let bearing {
            let camera = MKMapCamera(
                lookingAtCenter: center,
                fromDistance: map.camera.centerCoordinateDistance,
                pitch: 0,
                heading: bearing
            )
            map.setCamera(camera, animated: false)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject, MKMapViewDelegate {
        func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            if let tile = overlay as? MKTileOverlay {
                return MKTileOverlayRenderer(tileOverlay: tile)
            }
            return MKOverlayRenderer(overlay: overlay)
        }
    }
}
