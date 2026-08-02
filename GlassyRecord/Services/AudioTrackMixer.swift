import AVFoundation

/// Сводит mic + system audio в одну дорожку (Photos/AVPlayer часто играют только track 0).
enum AudioTrackMixer {
    static func mixToSingleTrackIfNeeded(
        sourceURL: URL,
        micVolume: Float,
        systemVolume: Float
    ) async throws -> URL {
        let asset = AVURLAsset(url: sourceURL)
        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        guard !audioTracks.isEmpty else {
            throw GlassyRecordError.screenRecordingFailed(L10n.t("error.audio_no_tracks"))
        }

        // Одна дорожка уже ок — только проверим, что она не пустая по длительности.
        if audioTracks.count == 1 {
            let duration = try await asset.load(.duration)
            guard duration.seconds > 0.05 else {
                throw GlassyRecordError.screenRecordingFailed(L10n.t("error.audio_empty"))
            }
            return sourceURL
        }

        let composition = AVMutableComposition()
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        let duration = try await asset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)

        if let sourceVideo = videoTracks.first,
           let compVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
           ) {
            try compVideo.insertTimeRange(range, of: sourceVideo, at: .zero)
            compVideo.preferredTransform = try await sourceVideo.load(.preferredTransform)
        }

        var mixParams: [AVMutableAudioMixInputParameters] = []
        for (index, track) in audioTracks.enumerated() {
            guard let compAudio = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) else { continue }
            try compAudio.insertTimeRange(range, of: track, at: .zero)
            let params = AVMutableAudioMixInputParameters(track: compAudio)
            // Track 0 = mic (writer order), track 1 = system.
            let volume = index == 0 ? micVolume : systemVolume
            params.setVolume(max(0, min(2, volume)), at: .zero)
            mixParams.append(params)
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mixed_\(UUID().uuidString).mp4")
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }

        guard let export = AVAssetExportSession(
            asset: composition,
            presetName: AVAssetExportPresetHighestQuality
        ) else {
            throw GlassyRecordError.exportFailed(L10n.t("error.audio_mix_session"))
        }
        export.outputURL = outputURL
        export.outputFileType = .mp4
        let mix = AVMutableAudioMix()
        mix.inputParameters = mixParams
        export.audioMix = mix

        await export.export()
        if let error = export.error {
            throw GlassyRecordError.exportFailed(error.localizedDescription)
        }

        // Заменяем исходный App Group файл смешанным — единый результат для редактора/Photos.
        try? FileManager.default.removeItem(at: sourceURL)
        try FileManager.default.copyItem(at: outputURL, to: sourceURL)
        try? FileManager.default.removeItem(at: outputURL)
        return sourceURL
    }
}
