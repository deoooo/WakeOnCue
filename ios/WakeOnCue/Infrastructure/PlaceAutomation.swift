import CoreLocation
import Foundation
import Observation
import UserNotifications

enum PlaceTriggerAction: String, Codable, CaseIterable, Identifiable, Sendable {
  case none
  case start
  case finish

  var id: String { rawValue }
}

/// A place where arriving or leaving starts or finishes a recording.
struct RecordingPlace: Codable, Equatable, Identifiable, Sendable {
  static let radiusOptions: [Double] = [100, 200, 500, 1_000]

  var id: String
  var name: String
  var latitude: Double
  var longitude: Double
  var radius: Double
  var onArrival: PlaceTriggerAction
  var onDeparture: PlaceTriggerAction

  var coordinate: CLLocationCoordinate2D {
    CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
  }

  var isActive: Bool { onArrival != .none || onDeparture != .none }
}

/// Watches the user's places in the background. iOS lets an app finish a recording it
/// is already making, but not open the microphone from the background, so arriving at a
/// "start" place posts a notification whose action opens WakeOnCue and starts recording.
@MainActor
@Observable
final class PlaceAutomation: NSObject {
  static let maximumPlaces = 20
  nonisolated static let startCategory = "place.start-recording"
  nonisolated static let startAction = "place.start-recording.action"
  private static let placesKey = "places.automation"
  private static let lastStatesKey = "places.last-states"
  private static let monitorName = "WakeOnCuePlaces"

  private(set) var places: [RecordingPlace] = []
  /// Unknown until `refreshAuthorization()` has asked the system.
  private(set) var authorization: CLAuthorizationStatus?
  /// Called with the configured action, the place, and whether the user arrived.
  @ObservationIgnored var onTrigger: ((PlaceTriggerAction, RecordingPlace, Bool) async -> Void)?
  @ObservationIgnored var onStartRequested: (() async -> Void)?

  /// Created only when the user asks for location access: creating one and reading its
  /// status wait synchronously on locationd, which must never block app launch. CLMonitor,
  /// which delivers place events after a background launch, does not need it.
  @ObservationIgnored private var manager: CLLocationManager?
  @ObservationIgnored private var monitor: CLMonitor?
  @ObservationIgnored private var eventsTask: Task<Void, Never>?

  override init() {
    super.init()
    if let data = UserDefaults.standard.data(forKey: Self.placesKey),
      let stored = try? JSONDecoder().decode([RecordingPlace].self, from: data)
    {
      places = stored
    }
    NotificationRouter.shared.register(
      UNNotificationCategory(
        identifier: Self.startCategory,
        actions: [
          UNNotificationAction(
            identifier: Self.startAction,
            title: AppLanguage.localized("Start Recording"),
            options: [.foreground]
          )
        ],
        intentIdentifiers: []
      )
    ) { [weak self] response in
      guard response.actionIdentifier == Self.startAction || response.isDefaultAction else { return }
      await self?.onStartRequested?()
    }
  }

  /// Must run on every launch, including background launches caused by place events.
  func start() {
    guard eventsTask == nil, places.contains(where: \.isActive) else { return }
    eventsTask = Task { [weak self] in
      let monitor = await CLMonitor(Self.monitorName)
      guard let self else { return }
      self.monitor = monitor
      await self.syncConditions()
      do {
        for try await event in await monitor.events {
          await self.handle(event)
        }
      } catch {
        self.eventsTask = nil
      }
    }
  }

  func save(_ place: RecordingPlace) async {
    if let index = places.firstIndex(where: { $0.id == place.id }) {
      places[index] = place
    } else {
      places.append(place)
    }
    persist()
    // A changed area must observe its state afresh rather than act on an old one.
    clearLastState(for: place.id)
    if place.onArrival == .start || place.onDeparture == .start {
      _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [
        .alert, .sound,
      ])
    }
    if place.isActive { await requestAuthorization() }
    start()
    await syncConditions()
  }

  func delete(id: String) async {
    places.removeAll { $0.id == id }
    persist()
    clearLastState(for: id)
    await syncConditions()
  }

  var hasLocationManager: Bool { manager != nil }

  func refreshAuthorization() async {
    authorization = await Task.detached { CLLocationManager().authorizationStatus }.value
  }

  func requestAuthorization() async {
    await refreshAuthorization()
    let manager = locationManager()
    switch authorization {
    case .notDetermined: manager.requestWhenInUseAuthorization()
    case .authorizedWhenInUse: manager.requestAlwaysAuthorization()
    default: break
    }
  }

  private func locationManager() -> CLLocationManager {
    if let manager { return manager }
    let created = CLLocationManager()
    created.delegate = self
    manager = created
    return created
  }

  func currentLocation() async throws -> CLLocation {
    await requestAuthorization()
    for try await update in CLLocationUpdate.liveUpdates() {
      if let location = update.location, location.horizontalAccuracy <= 200 { return location }
      if update.authorizationDenied || update.authorizationRestricted {
        throw PlaceAutomationError.locationDenied
      }
    }
    throw PlaceAutomationError.locationUnavailable
  }

  private func syncConditions() async {
    guard let monitor else { return }
    let active = Dictionary(uniqueKeysWithValues: places.filter(\.isActive).map { ($0.id, $0) })
    for identifier in await monitor.identifiers where active[identifier] == nil {
      await monitor.remove(identifier)
    }
    for place in active.values {
      await monitor.add(
        CLMonitor.CircularGeographicCondition(center: place.coordinate, radius: place.radius),
        identifier: place.id
      )
    }
  }

  private func handle(_ event: CLMonitor.Event) async {
    guard let place = places.first(where: { $0.id == event.identifier }) else { return }
    let inside: Bool
    switch event.state {
    case .satisfied: inside = true
    case .unsatisfied: inside = false
    default: return
    }
    // The first state seen for a place is only recorded, so adding a place while
    // standing in it does not count as arriving.
    var states = UserDefaults.standard.dictionary(forKey: Self.lastStatesKey) as? [String: Bool] ?? [:]
    let previous = states[place.id]
    states[place.id] = inside
    UserDefaults.standard.set(states, forKey: Self.lastStatesKey)
    guard let previous, previous != inside else { return }
    await onTrigger?(inside ? place.onArrival : place.onDeparture, place, inside)
  }

  func postStartPrompt(for place: RecordingPlace) async {
    let content = UNMutableNotificationContent()
    content.title = String(format: AppLanguage.localized("Arrived at %@"), place.name)
    content.body = AppLanguage.localized("Tap Start Recording to begin.")
    content.categoryIdentifier = Self.startCategory
    content.interruptionLevel = .timeSensitive
    try? await UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: "place.\(place.id)", content: content, trigger: nil))
  }

  func postFinishedNotice(for place: RecordingPlace, arrived: Bool) async {
    let content = UNMutableNotificationContent()
    content.title = String(
      format: AppLanguage.localized(arrived ? "Arrived at %@" : "Left %@"), place.name)
    content.body = AppLanguage.localized("The recording was finished and saved.")
    try? await UNUserNotificationCenter.current().add(
      UNNotificationRequest(identifier: "place.\(place.id)", content: content, trigger: nil))
  }

  private func persist() {
    if let data = try? JSONEncoder().encode(places) {
      UserDefaults.standard.set(data, forKey: Self.placesKey)
    }
  }

  private func clearLastState(for id: String) {
    var states = UserDefaults.standard.dictionary(forKey: Self.lastStatesKey) as? [String: Bool] ?? [:]
    states.removeValue(forKey: id)
    UserDefaults.standard.set(states, forKey: Self.lastStatesKey)
  }
}

extension PlaceAutomation: CLLocationManagerDelegate {
  nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
    let status = manager.authorizationStatus
    Task { @MainActor in
      self.authorization = status
      if status == .authorizedWhenInUse, self.places.contains(where: \.isActive) {
        self.manager?.requestAlwaysAuthorization()
      }
    }
  }
}

enum PlaceAutomationError: LocalizedError {
  case locationDenied
  case locationUnavailable

  var errorDescription: String? {
    switch self {
    case .locationDenied:
      AppLanguage.localized("Allow location access in iPhone Settings to use places.")
    case .locationUnavailable:
      AppLanguage.localized("Could not find your current location. Try again outside or search for the place.")
    }
  }
}
