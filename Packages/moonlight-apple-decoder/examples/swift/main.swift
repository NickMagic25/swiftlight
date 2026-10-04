import MoonlightAppleVideo
import CoreVideo

// Swift imports a Clang C module. Swift C++ interoperability is not enabled.
// A real consumer stores a strong CVPixelBuffer reference in its bounded queue;
// ARC then owns that reference independently of decoder reset/destruction.
func completion(_ context: UnsafeMutableRawPointer?, _ pointer: UnsafePointer<mav_completion>?) {
    guard let pointer else { return }
    let frame = pointer.pointee
    if let buffer = frame.pixel_buffer {
        let retained: CVPixelBuffer = buffer.takeUnretainedValue()
        withExtendedLifetime(retained) { _ = CVPixelBufferGetWidth(retained) }
    }
}
var config = mav_config()
mav_config_default(&config, MAV_CODEC_HEVC)
config.chroma_format = 3 // C/Swift ABI accepts an explicit full-resolution profile.
config.completion = completion
var decoder: OpaquePointer?
let created = mav_decoder_create(&config, &decoder)
precondition(created == MAV_OK)
precondition(mav_decoder_drain(decoder) == MAV_OK)
precondition(mav_decoder_reset(decoder) == MAV_OK)
precondition(mav_decoder_destroy(decoder) == MAV_OK)
var profile = mav_capability()
profile.struct_size = UInt32(MemoryLayout<mav_capability>.size)
profile.version = UInt32(MAV_ABI_VERSION)
precondition(mav_query_profile_capability(MAV_CODEC_HEVC, 12, 3, &profile) == MAV_INVALID_ARGUMENT)
precondition(profile.hardware_decode_candidate == 0)
print("PASS: Swift C ABI import and decoder ownership (no hardware decode claimed)")
