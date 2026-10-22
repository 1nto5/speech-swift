import AudioCommon

extension KokoroTTSModel: SpeechGenerationModel {
    public var sampleRate: Int { config.sampleRate }

    /// The bundle's default voice: `af_heart` when present, otherwise the
    /// bundle's single voice (the German bundles ship one voice each).
    public var defaultBundleVoice: String {
        voiceEmbeddings[Self.defaultVoice] != nil ? Self.defaultVoice : (availableVoices.first ?? Self.defaultVoice)
    }

    public func generate(text: String, language: String?) async throws -> [Float] {
        try synthesize(text: text, voice: defaultBundleVoice, language: language ?? "en")
    }

    public func generateStream(text: String, language: String?) -> AsyncThrowingStream<AudioChunk, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    // Kokoro is non-autoregressive — single shot, no streaming.
                    // Yield the full result as one chunk.
                    let audio = try self.synthesize(
                        text: text, voice: self.defaultBundleVoice, language: language ?? "en")
                    let chunk = AudioChunk(
                        samples: audio,
                        sampleRate: self.config.sampleRate,
                        frameIndex: 0,
                        isFinal: true
                    )
                    continuation.yield(chunk)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
