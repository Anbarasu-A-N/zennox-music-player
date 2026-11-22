# ADR-0004: Native audio engines + BSD Ogg/Opus decoders

Date: 2026-11-22 · Status: proposed (pending spike S3 codec matrix)

## Decision
Apple: AVAudioEngine with AVAudioFile/AudioToolbox for MP3, AAC/M4A, ALAC, FLAC, WAV, AIFF;
libogg + libvorbis + libopus (BSD-3) as SwiftPM C targets for Ogg Vorbis/Opus, fed to
AVAudioPlayerNode as PCM. Gapless via scheduling next buffer before current ends.
Android: Media3 ExoPlayer (FLAC, Opus, Vorbis, MP3, AAC, WAV natively; ALAC verified in S3,
fallback = Media3 FFmpeg extension built LGPL-only). Windows: Media Foundation + same BSD decoders.
Drive streaming: `files.get?alt=media` with HTTP Range into a bounded on-disk ring cache.

## Alternatives considered
- libmpv/FFmpeg everywhere — LGPL/GPL obligations and large binary; rejected for v1.
- AVPlayer — simpler but no Ogg, weaker gapless control.

## Consequences
We own a small decode→PCM pipeline for Ogg; codec matrix test per OS in CI and on devices.
