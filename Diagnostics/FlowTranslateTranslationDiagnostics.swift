import FlowTranslateCore
import Foundation

/// Offline replay of the production Apple translation queue. No language-pack
/// download or microphone permission is needed; only the host response is fake.
@main
struct FlowTranslateTranslationDiagnostics {
  @MainActor static func main() async {
    let service = TranslationService()
    var results: [UUID: String] = [:]
    var backendCalls = 0
    var pending: [TranslationService.Pending] = []
    var failNext = false
    service.onResult = { results[$0] = $1 }
    func startHost() -> Task<Void, Never> {
      let pair = service.languagePair
      let stream = service.makeStream(for: pair)
      return Task { @MainActor in
        for await request in stream {
          pending.append(request)
          if let cached = service.cachedTranslation(for: request) {
            service.complete(request, translation: cached, from: pair)
            continue
          }
          backendCalls += 1
          if failNext {
            failNext = false
            continue
          }
          service.complete(request, translation: "完整譯文：" + request.text, from: pair)
        }
      }
    }
    var host = startHost()
    var failures = 0
    func check(_ ok: Bool, _ message: String) {
      print("\(ok ? "PASS" : "FAIL") \(message)")
      if !ok { failures += 1 }
    }
    func settle() async { try? await Task.sleep(nanoseconds: 20_000_000) }

    let interim = UUID()
    let final = UUID()
    service.translate(id: interim, text: "A complete paragraph.")
    await settle()
    service.translate(id: final, text: "A complete paragraph.")
    check(
      results[final] == results[interim] && results[final] != nil && backendCalls == 1,
      "completed interim→final translation returns synchronously without a second backend call")

    let queuedA = UUID()
    let queuedB = UUID()
    service.translate(id: queuedA, text: "Queued paragraph.")
    service.translate(id: queuedB, text: "Queued paragraph.")
    await settle()
    check(
      backendCalls == 2 && results[queuedA] == results[queuedB] && results[queuedB] != nil,
      "duplicate queued before completion reuses the result at dequeue")

    service.translate(id: UUID(), text: "A changed paragraph.")
    await settle()
    check(backendCalls == 3, "changed finalized text still translates")

    let oldPair = service.languagePair
    service.targetLanguage = "en"
    let targetID = UUID()
    service.translate(id: targetID, text: "A complete paragraph.")
    await settle()
    check(
      backendCalls == 3 && results[targetID] == nil,
      "new-language request waits for its matching session")
    host.cancel()
    await host.value
    host = startHost()
    await settle()
    check(
      backendCalls == 4 && results[targetID] != nil,
      "new session receives the buffered request")
    var stale = service.makeStream(for: oldPair).makeAsyncIterator()
    check(await stale.next() == nil, "obsolete prepared session cannot replace the current stream")
    service.sourceLanguage = "fr"
    let sourceID = UUID()
    service.translate(id: sourceID, text: "A complete paragraph.")
    await settle()
    check(
      backendCalls == 4 && results[sourceID] == nil,
      "changed source language is also isolated")
    host.cancel()
    await host.value
    host = startHost()
    await settle()
    check(
      backendCalls == 5 && results[sourceID] != nil,
      "source and target changes cannot reuse another language pair")
    let mismatch = TranslationService.Pending(
      id: UUID(), text: "Wrong pair.", pair: service.languagePair)
    service.complete(mismatch, translation: "錯誤語言", from: oldPair)
    check(
      results[mismatch.id] == nil && service.cachedTranslation(for: mismatch) == nil,
      "mismatched session output cannot reach the UI or poison the cache")

    failNext = true
    let retry = UUID()
    service.translate(id: UUID(), text: "Retry after failure.")
    await settle()
    service.translate(id: retry, text: "Retry after failure.")
    await settle()
    check(backendCalls == 7 && results[retry] != nil, "failed translations are retried")

    let first = pending[0]
    for i in 0..<70 {
      service.translate(id: UUID(), text: "Bounded cache entry \(i).")
      await settle()
    }
    check(
      service.cachedTranslation(for: first) == nil
        && pending.last.flatMap { service.cachedTranslation(for: $0) } != nil,
      "completed cache evicts old entries and retains the latest")

    // This matches CaptureViewModel's finalization order: install the band
    // key before translate can synchronously return an already-cached value.
    let bandID = UUID()
    var band = CaptionBandState()
    band.commit(
      utteranceId: nil, source: .system,
      sentences: [(bandID, "Bounded cache entry 69.")], expectsTranslation: true)
    service.onResult = { id, text in band.translation(key: id, text: text) }
    service.translate(id: bandID, text: "Bounded cache entry 69.")
    check(
      band.committed.last?.chinese?.hasSuffix("69.") == true,
      "synchronous cached result reaches the committed overlay paragraph")
    host.cancel()
    await host.value
    print("RESULT failures=\(failures)")
    exit(failures == 0 ? 0 : 1)
  }
}
