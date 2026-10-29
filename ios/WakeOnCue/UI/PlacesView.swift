import CoreLocation
import MapKit
import SwiftUI

/// Places where arriving or leaving starts or finishes a recording.
struct PlacesView: View {
  @Environment(AppModel.self) private var model
  @State private var editing: RecordingPlace?

  var body: some View {
    let automation = model.places
    List {
      Section {
        ForEach(automation.places) { place in
          Button {
            editing = place
          } label: {
            VStack(alignment: .leading, spacing: 3) {
              Text(place.name).foregroundStyle(.primary)
              Text(summary(of: place))
                .font(.footnote)
                .foregroundStyle(.secondary)
            }
          }
        }
        .onDelete { offsets in
          let ids = offsets.map { automation.places[$0].id }
          Task { for id in ids { await automation.delete(id: id) } }
        }
        Button {
          editing = RecordingPlace(
            id: UUID().uuidString, name: "", latitude: 0, longitude: 0, radius: 200,
            onArrival: .start, onDeparture: .finish)
        } label: {
          Label("Add place", systemImage: "plus")
        }
        .disabled(automation.places.count >= PlaceAutomation.maximumPlaces)
        .accessibilityIdentifier("places.add")
      } footer: {
        Text(
          "iOS does not let apps open the microphone from the background. When you arrive at a place set to start, WakeOnCue sends a notification; tap it to begin. Finishing happens automatically. For a fully automatic start, add an Arrive automation in the Shortcuts app that runs Start Meeting Recording."
        )
      }
      if automation.places.contains(where: \.isActive),
        automation.authorization != .authorizedAlways
      {
        Section {
          Label(
            "Set location access to Always so places work while WakeOnCue is closed.",
            systemImage: "location.slash"
          )
          .foregroundStyle(.orange)
          Button("Open iPhone Settings") { model.openSystemSettings() }
        }
      }
    }
    .navigationTitle("Places")
    .sheet(item: $editing) { place in
      NavigationStack {
        PlaceEditorView(place: place)
      }
    }
  }

  private func summary(of place: RecordingPlace) -> String {
    [
      place.onArrival == .none
        ? nil : "\(AppLanguage.localized("Arrive")): \(title(of: place.onArrival))",
      place.onDeparture == .none
        ? nil : "\(AppLanguage.localized("Leave")): \(title(of: place.onDeparture))",
    ].compactMap { $0 }.joined(separator: " · ")
  }
}

func title(of action: PlaceTriggerAction) -> String {
  switch action {
  case .none: AppLanguage.localized("Do nothing")
  case .start: AppLanguage.localized("Start recording")
  case .finish: AppLanguage.localized("Finish recording")
  }
}

struct PlaceEditorView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismiss) private var dismiss
  @State private var place: RecordingPlace
  @State private var hasLocation: Bool
  @State private var query = ""
  @State private var results: [MKMapItem] = []
  @State private var isLocating = false
  @State private var errorMessage: String?

  init(place: RecordingPlace) {
    _place = State(initialValue: place)
    _hasLocation = State(initialValue: place.latitude != 0 || place.longitude != 0)
  }

  var body: some View {
    Form {
      Section {
        TextField("Name", text: $place.name)
          .accessibilityIdentifier("places.name")
      }
      Section("Location") {
        if hasLocation {
          Map(
            initialPosition: .region(
              MKCoordinateRegion(
                center: place.coordinate,
                latitudinalMeters: place.radius * 4,
                longitudinalMeters: place.radius * 4))
          ) {
            Marker(place.name, coordinate: place.coordinate)
            MapCircle(center: place.coordinate, radius: place.radius)
              .foregroundStyle(.cyan.opacity(0.2))
          }
          .id("\(place.latitude),\(place.longitude),\(place.radius)")
          .frame(height: 180)
          .listRowInsets(EdgeInsets())
        }
        Button {
          useCurrentLocation()
        } label: {
          if isLocating {
            HStack {
              ProgressView().controlSize(.small)
              Text("Finding your location…")
            }
          } else {
            Label("Use current location", systemImage: "location.fill")
          }
        }
        .disabled(isLocating)
        TextField("Search for an address or place", text: $query)
          .onSubmit { search() }
          .submitLabel(.search)
        ForEach(results, id: \.self) { item in
          Button {
            choose(item)
          } label: {
            VStack(alignment: .leading) {
              Text(item.name ?? "").foregroundStyle(.primary)
              if let address = item.placemark.title {
                Text(address).font(.footnote).foregroundStyle(.secondary)
              }
            }
          }
        }
        Picker("Radius", selection: $place.radius) {
          ForEach(RecordingPlace.radiusOptions, id: \.self) { radius in
            Text(Measurement(value: radius, unit: UnitLength.meters).formatted(.measurement(width: .abbreviated)))
              .tag(radius)
          }
        }
      }
      Section {
        Picker("When I arrive", selection: $place.onArrival) {
          ForEach(PlaceTriggerAction.allCases) { Text(title(of: $0)).tag($0) }
        }
        Picker("When I leave", selection: $place.onDeparture) {
          ForEach(PlaceTriggerAction.allCases) { Text(title(of: $0)).tag($0) }
        }
      } footer: {
        Text("Place names and locations stay on this iPhone.")
      }
    }
    .navigationTitle(place.name.isEmpty ? AppLanguage.localized("New place") : place.name)
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .cancellationAction) {
        Button("Cancel") { dismiss() }
      }
      ToolbarItem(placement: .confirmationAction) {
        Button("Save") {
          var saved = place
          saved.name = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
          Task {
            await model.places.save(saved)
            dismiss()
          }
        }
        .disabled(place.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !hasLocation)
      }
    }
    .alert("Could not find the place", isPresented: errorBinding) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "")
    }
  }

  private func useCurrentLocation() {
    isLocating = true
    Task {
      defer { isLocating = false }
      do {
        let location = try await model.places.currentLocation()
        place.latitude = location.coordinate.latitude
        place.longitude = location.coordinate.longitude
        hasLocation = true
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func search() {
    let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = text
    Task {
      do {
        results = Array(try await MKLocalSearch(request: request).start().mapItems.prefix(6))
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  private func choose(_ item: MKMapItem) {
    let coordinate = item.placemark.coordinate
    place.latitude = coordinate.latitude
    place.longitude = coordinate.longitude
    if place.name.isEmpty { place.name = item.name ?? "" }
    hasLocation = true
    results = []
    query = ""
  }

  private var errorBinding: Binding<Bool> {
    Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
  }
}
