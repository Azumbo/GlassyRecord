import AVFoundation
import Photos
import UIKit

/// Экспорт записей в H.264/HEVC и сохранение в галерею.
actor ExportService {
    enum ExportDestination {
        case photoLibrary
        case share(URL)
    }

    func export(
        asset: AVAsset,
        codec: ExportCodec,
        trimRange: CMTimeRange?
    ) async throws -> URL {
        let composition = AVMutableComposition()
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let sourceVideo = videoTracks.first else {
            throw GlassyRecordError.exportFailed(L10n.t("error.video_track_missing"))
        }

        guard let compVideo = composition.addMutableTrack(
            withMediaType: .video,
            preferredTrackID: kCMPersistentTrackID_Invalid
        ) else {
            throw GlassyRecordError.exportFailed(L10n.t("error.composition_failed"))
        }

        let duration = try await asset.load(.duration)
        let range = trimRange ?? CMTimeRange(start: .zero, duration: duration)
        try compVideo.insertTimeRange(range, of: sourceVideo, at: .zero)

        let audioTracks = try await asset.loadTracks(withMediaType: .audio)
        for track in audioTracks {
            if let compAudio = composition.addMutableTrack(
                withMediaType: .audio,
                preferredTrackID: kCMPersistentTrackID_Invalid
            ) {
                try? compAudio.insertTimeRange(range, of: track, at: .zero)
            }
        }

        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("export_\(UUID().uuidString).mp4")

        guard let exportSession = AVAssetExportSession(
            asset: composition,
            presetName: codec == .hevc
                ? AVAssetExportPresetHEVCHighestQuality
                : AVAssetExportPresetHighestQuality
        ) else {
            throw GlassyRecordError.exportFailed(L10n.t("error.export_session_failed"))
        }

        exportSession.outputURL = outputURL
        exportSession.outputFileType = .mp4

        await exportSession.export()

        if let error = exportSession.error {
            throw GlassyRecordError.exportFailed(error.localizedDescription)
        }

        return outputURL
    }

    func saveToPhotoLibrary(url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw GlassyRecordError.permissionDenied(L10n.t("permission.photos"))
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }

    func generateThumbnail(for url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 180)

        guard let (image, _) = try? await generator.image(at: .zero) else { return nil }
        return UIImage(cgImage: image).jpegData(compressionQuality: 0.8)
    }
}
