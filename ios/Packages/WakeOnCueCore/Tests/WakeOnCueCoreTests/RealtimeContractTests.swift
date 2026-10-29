import Foundation
import Testing

@testable import WakeOnCueCore

@Test func realtimeSessionRequestUsesStableWireKeys() throws {
  let request = RealtimeSessionRequest(recordingID: "rec_test", language: "zh-Hans")
  let object = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
  )

  #expect(object["protocol_version"] as? Int == 1)
  #expect(object["recording_id"] as? String == "rec_test")
  let audio = try #require(object["audio"] as? [String: Any])
  #expect(audio["encoding"] as? String == "pcm_s16le")
  #expect(audio["sample_rate"] as? Int == 24_000)
  #expect(audio["channels"] as? Int == 1)
}

@Test func transcriptEventDecodesSpeakerAndRevision() throws {
  let payload = Data(
    #"{"protocol_version":1,"type":"transcript.upsert","recording_id":"rec_test","segment_id":"seg_1","revision":4,"start_ms":1200,"end_ms":3100,"text":"Hello","is_final":true,"speaker":{"cluster_id":"speaker_1","person_id":null,"display_name":"Speaker 1","confidence":0.82}}"#
      .utf8
  )
  let event = try JSONDecoder().decode(RealtimeTranscriptEvent.self, from: payload)

  #expect(event.revision == 4)
  #expect(event.isFinal)
  #expect(event.speaker?.displayName == "Speaker 1")
}

@Test func realtimeSessionRequestCarriesSpeakerOptionsOnlyWhenEnabled() throws {
  let voice = RealtimeKnownVoiceprint(
    personID: RealtimeSpeaker.selfPersonID,
    voiceprint: RealtimeVoiceprint(model: "eres2net", embedding: [0.25, -0.5])
  )
  let anonymous = try #require(
    JSONSerialization.jsonObject(
      with: JSONEncoder().encode(
        RealtimeSessionRequest(recordingID: "rec", language: nil, knownVoiceprints: [voice]))
    ) as? [String: Any]
  )
  #expect(anonymous["speaker_diarization"] == nil)
  #expect(anonymous["known_voiceprints"] == nil)

  let request = RealtimeSessionRequest(
    recordingID: "rec", language: nil, speakerDiarization: true, knownVoiceprints: [voice]
  )
  let object = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
  )
  #expect(object["speaker_diarization"] as? Bool == true)
  let voices = try #require(object["known_voiceprints"] as? [[String: Any]])
  #expect(voices.first?["person_id"] as? String == "self")
  #expect(voices.first?["embedding"] as? [Double] == [0.25, -0.5])
}

@Test func voiceprintEnrollmentUsesStableWireKeys() throws {
  let request = RealtimeVoiceprintEnrollmentRequest(pcm16LittleEndian: Data([1, 2, 3]))
  let object = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? [String: Any]
  )
  #expect(object["protocol_version"] as? Int == 1)
  #expect(object["audio_base64"] as? String == "AQID")
  #expect((object["audio"] as? [String: Any])?["sample_rate"] as? Int == 24_000)

  let response = try JSONDecoder().decode(
    RealtimeVoiceprintEnrollmentResponse.self,
    from: Data(
      #"{"protocol_version":1,"voiceprint":{"model":"m","embedding":[0.1,0.2]},"speech_ms":15200}"#
        .utf8)
  )
  #expect(response.voiceprint == RealtimeVoiceprint(model: "m", embedding: [0.1, 0.2]))
  #expect(response.speechMilliseconds == 15_200)
}

@Test func realtimeSessionRequestSendsChannelOnlyWhenSet() throws {
  let single = try #require(
    JSONSerialization.jsonObject(
      with: JSONEncoder().encode(RealtimeSessionRequest(recordingID: "rec", language: nil)))
      as? [String: Any]
  )
  #expect(single["channel"] == nil)

  let microphone = try #require(
    JSONSerialization.jsonObject(
      with: JSONEncoder().encode(
        RealtimeSessionRequest(recordingID: "rec", language: nil, channel: .microphone)))
      as? [String: Any]
  )
  #expect(microphone["channel"] as? String == "microphone")
}

@Test func channelTranscriptEventsHaveDistinctIdentities() throws {
  func event(_ channel: String) throws -> RealtimeTranscriptEvent {
    try JSONDecoder().decode(
      RealtimeTranscriptEvent.self,
      from: Data(
        #"{"protocol_version":1,"type":"transcript.upsert","recording_id":"rec","segment_id":"seg_0","revision":1,"start_ms":0,"end_ms":900,"text":"Hi","is_final":true,"speaker":null,"channel":"\#(channel)"}"#
          .utf8)
    )
  }
  let microphone = try event("microphone")
  let system = try event("system")
  #expect(microphone.channel == .microphone)
  #expect(system.channel == .system)
  #expect(microphone.id != system.id)
}
