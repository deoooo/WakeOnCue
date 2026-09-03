import Testing

@testable import WakeOnCueCore

@Test func validatesLifecycleTransitions() throws {
  try RecordingStateMachine.validate(from: .recording, to: .paused)
  try RecordingStateMachine.validate(from: .paused, to: .recording)
  try RecordingStateMachine.validate(from: .recording, to: .finishing)
  try RecordingStateMachine.validate(from: .finishing, to: .uploading)
  try RecordingStateMachine.validate(from: .uploading, to: .completed)
}

@Test func rejectsLifecycleShortcut() {
  #expect(throws: RecordingStateError.invalidTransition(from: .recording, to: .completed)) {
    try RecordingStateMachine.validate(from: .recording, to: .completed)
  }
}

@Test func waitingDurationAdvancesBetweenPersistedChunkRefreshes() {
  let persisted = RecordingSyncProgress(uploadedDuration: 10, pendingDuration: 5)

  let afterOneSecond = persisted.includingUnindexedDuration(16)
  #expect(afterOneSecond.uploadedDuration == 10)
  #expect(afterOneSecond.pendingDuration == 6)

  let afterAnotherSecond = afterOneSecond.includingUnindexedDuration(17)
  #expect(afterAnotherSecond.pendingDuration == 7)
}
