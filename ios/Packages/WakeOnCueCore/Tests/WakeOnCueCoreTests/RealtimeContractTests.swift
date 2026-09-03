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
