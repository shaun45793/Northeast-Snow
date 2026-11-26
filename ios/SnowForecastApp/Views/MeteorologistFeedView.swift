import SnowForecastKit
import SwiftUI

struct MeteorologistFeedView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if !appState.regionalPosts.isEmpty {
                        Text("Regional Ski Meteorologists & Summits")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .padding(.top, 4)

                        ForEach(appState.regionalPosts) { post in
                            regionalPostCard(post)
                        }
                    }

                    Text("NWS Forecast Office Discussions")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.top, 6)

                    ForEach(appState.discussions) { discussion in
                        NavigationLink(value: discussion) {
                            DiscussionCard(discussion: discussion)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .background(AlpineTheme.background.ignoresSafeArea())
            .navigationTitle("Local Meteorologists")
            .refreshable {
                await appState.refreshDiscussions()
                await appState.refreshRegionalPosts()
            }
            .navigationDestination(for: MeteorologistDiscussion.self) { discussion in
                DiscussionDetailView(discussion: discussion)
            }
        }
    }

    private func regionalPostCard(_ post: RegionalForecastPost) -> some View {
        Button {
            if let url = URL(string: post.urlString) {
                openURL(url)
            }
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(post.sourceName.uppercased())
                        .font(.caption2.bold())
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(AlpineTheme.powderBlue.opacity(0.2), in: Capsule())
                        .foregroundStyle(AlpineTheme.iceCyan)
                    Spacer()
                    Text(post.publishedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.55))
                }

                Text(post.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.leading)

                Text(post.summary)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.82))
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)

                HStack {
                    if let author = post.author {
                        Text(author)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    Spacer()
                    Label("Open Full Post", systemImage: "arrow.up.right.square")
                        .font(.caption2.bold())
                        .foregroundStyle(AlpineTheme.powderBlue)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AlpineTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(AlpineTheme.powderBlue.opacity(0.22), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct DiscussionCard: View {
    let discussion: MeteorologistDiscussion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(discussion.wfoId)
                    .font(.caption.bold())
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(AlpineTheme.forestMint.opacity(0.2), in: Capsule())
                    .foregroundStyle(AlpineTheme.forestMint)

                Text(discussion.wfoName)
                    .font(.headline)
                    .foregroundStyle(.white)

                Spacer()

                Text(discussion.issuedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
            }

            if let firstTakeaway = discussion.plainEnglishTakeaways.first {
                Text(firstTakeaway)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(AlpineTheme.iceCyan)
                    .lineLimit(3)
            }

            Text(discussion.mountainRelevanceSummary)
                .font(.caption)
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(3)

            if !discussion.highlights.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(discussion.highlights) { h in
                            Text(h.category)
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(AlpineTheme.cardElevated, in: Capsule())
                                .foregroundStyle(AlpineTheme.powderBlue)
                        }
                    }
                }
            }

            HStack {
                Text("Covers \(discussion.coveredMountainIds.count) Northeast ski areas")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Text(discussion.isLive ? "Live NWS AFD" : "Cached Preview")
                    .font(.caption2.bold())
                    .foregroundStyle(discussion.isLive ? AlpineTheme.forestMint : AlpineTheme.amberAlert)
            }
        }
        .padding(16)
        .background(AlpineTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
    }
}

struct DiscussionDetailView: View {
    let discussion: MeteorologistDiscussion
    @State private var showRawAFD: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(discussion.wfoName)
                            .font(.title3.bold())
                            .foregroundStyle(.white)
                        Spacer()
                        if let forecaster = discussion.forecaster {
                            Text("Forecaster: \(forecaster)")
                                .font(.caption)
                                .foregroundStyle(AlpineTheme.powderBlue)
                        }
                    }
                    Text("Issued \(discussion.issuedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                }

                if !discussion.plainEnglishTakeaways.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Plain-English Skier Summary", systemImage: "figure.skiing.downhill")
                            .font(.headline)
                            .foregroundStyle(AlpineTheme.iceCyan)

                        ForEach(discussion.plainEnglishTakeaways, id: \.self) { bullet in
                            HStack(alignment: .top, spacing: 8) {
                                Text("•")
                                    .foregroundStyle(AlpineTheme.powderBlue)
                                Text(bullet)
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.92))
                            }
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AlpineTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
                }

                if !discussion.highlights.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        Label("Extracted Ski & Mountain Highlights", systemImage: "sparkles")
                            .font(.headline)
                            .foregroundStyle(.white)

                        ForEach(discussion.highlights) { item in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.category.uppercased())
                                    .font(.caption2.bold())
                                    .foregroundStyle(AlpineTheme.powderBlue)
                                Text(item.summary)
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.9))
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AlpineTheme.cardElevated, in: RoundedRectangle(cornerRadius: 12))
                        }
                    }
                    .padding(14)
                    .background(AlpineTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
                }

                if let synopsis = discussion.synopsis {
                    sectionCard(title: "Synopsis", body: synopsis)
                }
                if let shortTerm = discussion.shortTerm {
                    sectionCard(title: "Short Term (0–72h)", body: shortTerm)
                }
                if let longTerm = discussion.longTerm {
                    sectionCard(title: "Long Term (Day 3–7)", body: longTerm)
                }

                DisclosureGroup("Raw NWS Area Forecast Discussion", isExpanded: $showRawAFD) {
                    Text(discussion.rawText)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.8))
                        .padding(.top, 8)
                }
                .tint(AlpineTheme.powderBlue)
                .foregroundStyle(.white)
                .padding(14)
                .background(AlpineTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
            }
            .padding(16)
        }
        .background(AlpineTheme.background.ignoresSafeArea())
        .navigationTitle("NWS \(discussion.wfoId)")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func sectionCard(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(AlpineTheme.iceCyan)
            Text(body)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AlpineTheme.cardBackground, in: RoundedRectangle(cornerRadius: 16))
    }
}
