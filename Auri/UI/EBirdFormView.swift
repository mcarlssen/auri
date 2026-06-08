import AppKit
import CoreLocation
import SwiftUI

struct EBirdFormView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var locationProvider = LocationProvider()

    let detection: BirdDetection?
    let species: [Bird]

    @State private var selectedBirdID: Int = 0
    @State private var observedDate = Date()
    @State private var location = ""
    @State private var method = "Audio"
    @State private var notes = ""
    @State private var feedback = ""

    private let methods = ["Audio", "Direct ID"]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Submit to eBird")
                .font(.title2.bold())

            Picker("Species", selection: $selectedBirdID) {
                Text("Select species").tag(0)
                ForEach(species) { bird in
                    Text(bird.commonName).tag(bird.id)
                }
            }

            DatePicker("Observed", selection: $observedDate, displayedComponents: [.date, .hourAndMinute])

            TextField("Location", text: $location)

            Picker("Method", selection: $method) {
                ForEach(methods, id: \.self) { value in
                    Text(value).tag(value)
                }
            }

            TextField("Notes", text: $notes, axis: .vertical)
                .lineLimit(3...5)

            if !feedback.isEmpty {
                Text(feedback)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel") { dismiss() }
                Spacer()
                Button("Open eBird", action: submit)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            if let detection {
                selectedBirdID = detection.birdId
                notes = "Detected by Auri at \(detection.confidence * 100)% confidence."
            }
            locationProvider.request()
            if let coordinate = locationProvider.lastKnownLocation?.coordinate {
                location = String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
            }
        }
    }

    private func submit() {
        let birdName = species.first(where: { $0.id == selectedBirdID })?.commonName
            ?? detection?.birdName
            ?? "Unknown species"

        EBirdSubmission.submit(
            birdName: birdName,
            observedDate: observedDate,
            location: location,
            method: method,
            notes: notes
        )

        feedback = "Observation summary copied to clipboard. Complete submission in your browser."
    }
}

final class LocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published var lastKnownLocation: CLLocation?
    private var manager: CLLocationManager?

    func request() {
        let manager = CLLocationManager()
        self.manager = manager
        manager.delegate = self
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        if let loc = locations.last {
            lastKnownLocation = loc
            manager.stopUpdatingLocation()
        }
    }
}
