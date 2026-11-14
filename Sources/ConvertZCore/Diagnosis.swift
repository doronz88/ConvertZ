import Foundation

/// Plain-language reasons Premiere Pro is likely to reject or mishandle a file.
public enum Diagnosis {
    static let goodVideoCodecs: Set<String> = ["h264", "hevc", "prores", "dnxhd", "mpeg2video", "dvvideo", "mjpeg"]
    static let goodAudioCodecs: Set<String> = ["aac", "mp3"]

    public static func issues(for info: MediaInfo) -> [String] {
        var out: [String] = []
        let format = info.formatName

        if format.contains("matroska") || format.contains("webm") {
            out.append("MKV/WebM container, which Premiere cannot import")
        } else if format.contains("flv") {
            out.append("FLV container, which Premiere cannot import")
        } else if format.contains("ogg") {
            out.append("Ogg container, which Premiere cannot import")
        } else if format.contains("asf") {
            out.append("WMV/ASF container, which Premiere on Mac cannot import")
        }

        if let v = info.video {
            if v.isVariableFrameRate {
                out.append("Variable frame rate, which causes audio drift and import errors")
            }
            if !goodVideoCodecs.contains(v.codec) {
                out.append("\(MediaInfo.displayName(v.codec)) video, which Premiere handles poorly or not at all")
            } else if v.codec == "h264", v.bitDepth > 8 || !v.is420 {
                out.append("H.264 in a 10-bit or 4:2:2/4:4:4 flavour that Premiere often refuses")
            }
            if v.isHDR {
                out.append("HDR video; it converts to standard range without tone-mapping, so colours may look flat")
            }
            if v.isInterlaced {
                out.append("Interlaced video; it will be deinterlaced")
            }
            if v.width % 2 != 0 || v.height % 2 != 0 {
                out.append("Odd pixel dimensions (\(v.width)×\(v.height))")
            }
        }

        for a in info.audio {
            if !goodAudioCodecs.contains(a.codec) && !a.codec.hasPrefix("pcm_") {
                // FLAC/ALAC on their own are fine as audio files; inside a video they are a problem.
                if info.video == nil, ["flac", "alac"].contains(a.codec), !format.contains("matroska") { continue }
                out.append("\(MediaInfo.displayName(a.codec)) audio, which Premiere cannot read here")
                break
            }
        }
        if let rate = info.audio.first?.sampleRate, ![44100, 48000, 88200, 96000].contains(rate) {
            out.append("Unusual audio sample rate (\(rate) Hz)")
        }
        if info.duration == nil {
            out.append("No duration information; the file may be truncated or missing its index")
        }
        return out
    }
}
