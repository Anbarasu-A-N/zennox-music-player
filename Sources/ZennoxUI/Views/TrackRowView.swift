#if canImport(SwiftUI)
import SwiftUI
import ZennoxCore

/// DESIGN.md §4 track row: artwork, title + artist/album, quality badge, duration, favourite.
struct TrackRowView: View {
    let track: TrackRow
    let onToggleFavorite: () -> Void

    private var subtitle: String {
        [track.artist, track.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — ")
    }

    private var isUnavailable: Bool { track.status != .ok }

    var body: some View {
        HStack(spacing: 12) {
            ArtworkPlaceholder(size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(track.title).font(.body).lineLimit(1)
                if isUnavailable {
                    Label(track.status == .missing ? "File missing" : "Not accessible", systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(ZennoxTheme.warning)
                } else if !subtitle.isEmpty {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if track.sourceKind == .googleDrive {
                Image(systemName: "icloud").foregroundStyle(.secondary).accessibilityLabel("Google Drive")
            }
            QualityBadge(codec: track.codec)
            Text(QualityFormatter.duration(ms: track.durationMs))
                .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
            Button(action: onToggleFavorite) {
                Image(systemName: track.isFavorite ? "heart.fill" : "heart")
                    .foregroundStyle(track.isFavorite ? ZennoxTheme.accent : Color.secondary)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(track.isFavorite ? "Remove from Favorites" : "Add to Favorites")
        }
        .frame(minHeight: 44)
        .opacity(isUnavailable ? 0.5 : 1)
        .accessibilityElement(children: .contain)
    }
}

struct QualityBadge: View {
    let codec: Codec

    var body: some View {
        Text(QualityFormatter.badge(codec))
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(codec.isLossless ? ZennoxTheme.lossless : Color.secondary)
            .overlay(Capsule().strokeBorder(codec.isLossless ? ZennoxTheme.lossless : Color.secondary.opacity(0.4)))
            .accessibilityLabel(codec.isLossless ? "Lossless" : "Format \(QualityFormatter.codecName(codec))")
    }
}

struct ArtworkPlaceholder: View {
    let size: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: size > 60 ? 12 : 6, style: .continuous)
            .fill(ZennoxTheme.artworkPlaceholder)
            .frame(width: size, height: size)
            .overlay(Image(systemName: "music.note").font(.system(size: size * 0.4)).foregroundStyle(.tertiary))
            .accessibilityHidden(true)
    }
}
#endif
