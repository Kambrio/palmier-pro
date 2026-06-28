import Foundation

/// A suggested story node: a title + a one-line summary the user/AI can instantiate. `recommended`
/// flags the core structure that best fits the parent direction.
struct StoryTemplate: Sendable, Equatable {
    let title: String
    let summary: String
    var recommended: Bool = false
}

/// Default story-development options for turning ALREADY-SHOT footage into an edited video. Every
/// template is framed for post-production — selecting, ordering, and cutting the clips you have, not
/// planning a shoot. Each direction has a core recommended structure drawn from how travel /
/// day-in-the-life / cinematic creators actually montage footage on YouTube.
enum StoryTemplates {
    /// Top-level direction/genre options (editing-framed).
    static let directions: [StoryTemplate] = [
        .init(title: "Cinematic life vlog", summary: "Cut everyday/lifestyle footage into a slow, mood-driven montage with reflective voiceover and music-synced b-roll."),
        .init(title: "Travel vlog", summary: "Shape trip footage into a journey: arrival, discovery, obstacles, a peak moment, and reflection."),
        .init(title: "Day in the life", summary: "Edit a day's footage into an arc with stakes — routine compressed, key moments slowed down."),
        .init(title: "Documentary short", summary: "Organize footage into a non-fiction arc: a question, exploration, tension, revelation, meaning."),
        .init(title: "Tutorial / how-to", summary: "Sequence demo footage: problem → steps → payoff, clear and paced."),
        .init(title: "Product / brand", summary: "Cut into problem → solution → demo → proof → call to action."),
        .init(title: "Event recap", summary: "Condense event footage into emotionally paced highlights, not strict chronology."),
        .init(title: "Montage / highlight", summary: "A music-led cut of your best moments with varied rhythm and a clear peak."),
    ]

    /// Which structure is the core recommendation for each direction.
    private static let recommendedByDirection: [String: String] = [
        "Cinematic life vlog": "Cinematic life",
        "Travel vlog": "Travel story",
        "Day in the life": "Day arc",
        "Documentary short": "Documentary arc",
        "Tutorial / how-to": "Problem → Solution",
        "Product / brand": "Problem → Solution",
        "Event recap": "Highlight arc",
        "Montage / highlight": "Montage arc",
    ]

    /// All story structures (children of a direction). The first several are the research-grounded
    /// spines that creators use to cut travel/life footage; the rest are general-purpose.
    static let structures: [StoryTemplate] = [
        .init(title: "Travel story", summary: "Hook (in medias res) → context → goal → obstacles → micro-stories → climax → reflection → outro. The core travel-vlog cut."),
        .init(title: "Day arc", summary: "Hook → morning prep (montage) → journey → main activity → complication → reflection. A day with stakes."),
        .init(title: "Cinematic life", summary: "Cold-open → establishing → discovery → rising moments → reflection → climax → resolution → outro. Mood-led, retrospective."),
        .init(title: "Documentary arc", summary: "Question/hook → establish subject → exploration → tension → revelation → meaning."),
        .init(title: "Highlight arc", summary: "Teaser → scene-set → peak → bigger peak → candid/human → climax → closing sentiment."),
        .init(title: "Montage arc", summary: "Beat-drop intro → escalation → varied-rhythm section → peak → wind-down → outro."),
        .init(title: "Hook → Build → Payoff", summary: "Short-form default: open on your strongest clip, escalate, then land the payoff."),
        .init(title: "Problem → Solution", summary: "Problem → agitation → solution/steps → proof → CTA. Tutorials and product."),
        .init(title: "Three-act", summary: "Setup → confrontation (rising obstacles, midpoint turn) → resolution."),
        .init(title: "Kishōtenketsu", summary: "Intro → development → twist → reconciliation. No conflict needed; reflective."),
        .init(title: "Story circle", summary: "You → need → go → search → find → take → return → change. Character-driven."),
        .init(title: "Before / After", summary: "Establish the before, show the process, reveal the after, reflect."),
    ]

    private static let beatsByStructure: [String: [StoryTemplate]] = [
        "Travel story": [
            .init(title: "Hook (in medias res)", summary: "Cold-open on the trip's most intense or beautiful clip, before any context."),
            .init(title: "Context", summary: "A short establishing sequence + line: where you are, why it matters, what to expect (<1 min)."),
            .init(title: "Goal & stakes", summary: "State the objective or question the trip is built around (reach the viewpoint, find the hidden cafés)."),
            .init(title: "Obstacles", summary: "Cut the roadblocks you filmed so each follows 'therefore/but', not 'and then' — keep cause-and-effect."),
            .init(title: "Micro-stories", summary: "Build mini-arcs from encounters and characters you captured: meeting → interaction → outcome."),
            .init(title: "Climax", summary: "The peak moment of the trip — hold it and let music carry it."),
            .init(title: "Reflection", summary: "A retrospective voiceover or sit-down: what it meant, what changed."),
            .init(title: "Outro", summary: "Brief sign-off or next-episode tease."),
        ],
        "Day arc": [
            .init(title: "Hook", summary: "Open on the day's most interesting beat, or a question/stake for the day."),
            .init(title: "Morning prep", summary: "Compress the routine into a montage or time-lapse from your morning clips."),
            .init(title: "Journey", summary: "Use commute/transition footage to move between chapters."),
            .init(title: "Main activity", summary: "The day's core event in full coverage — wide, medium, close."),
            .init(title: "Complication", summary: "The unexpected problem or surprise that breaks the routine."),
            .init(title: "Reflection", summary: "An end-of-day reflection: what the day added up to."),
        ],
        "Cinematic life": [
            .init(title: "Cold-open hook", summary: "1–2 of your most striking clips, no dialogue, music builds. J-cut in."),
            .init(title: "Establishing", summary: "Wide location clips; calm; answer where/when/why."),
            .init(title: "Discovery", summary: "A montage of detail→medium→wide shots, music-synced, with match cuts."),
            .init(title: "Rising moments", summary: "Varied activity + reactions you filmed; energy builds; L/J cuts."),
            .init(title: "Reflection", summary: "One held shot, intimate voiceover, music pulls back."),
            .init(title: "Climax", summary: "The earned peak moment; crescendo; hold the frame."),
            .init(title: "Resolution", summary: "Wind-down b-roll; tone mirrors the open; music resolves."),
            .init(title: "Outro", summary: "Short branding / CTA; clean fade."),
        ],
        "Documentary arc": [
            .init(title: "Question / hook", summary: "Open on the compelling question or its most charged moment."),
            .init(title: "Establish subject", summary: "Who/what this is about and why it matters."),
            .init(title: "Exploration", summary: "The investigative middle — details, interviews, b-roll."),
            .init(title: "Tension", summary: "What's at stake; the complication or conflict."),
            .init(title: "Revelation", summary: "The turn or discovery the footage builds to."),
            .init(title: "Meaning", summary: "Closing reflection: why it matters."),
        ],
        "Highlight arc": [
            .init(title: "Teaser", summary: "Open on the single best moment as a cold tease."),
            .init(title: "Scene-set", summary: "Establish the venue, scale, and energy."),
            .init(title: "Peak", summary: "The first standout moment."),
            .init(title: "Bigger peak", summary: "Escalate to a second, larger highlight."),
            .init(title: "Candid / human", summary: "Authentic reactions and connection."),
            .init(title: "Climax", summary: "The emotional or showpiece high point."),
            .init(title: "Closing sentiment", summary: "Gratitude / impact / next-time."),
        ],
        "Montage arc": [
            .init(title: "Beat-drop intro", summary: "Music begins on your first striking image."),
            .init(title: "Escalation", summary: "Rising energy and visual interest."),
            .init(title: "Varied rhythm", summary: "Mix quick cuts and held moments; never an even rhythm."),
            .init(title: "Peak", summary: "Your most impressive or emotional clip."),
            .init(title: "Wind-down", summary: "Ease the pace slightly."),
            .init(title: "Outro", summary: "Fade, freeze-frame, or title reveal."),
        ],
        "Hook → Build → Payoff": [
            .init(title: "Hook", summary: "Open on your single strongest clip — the most striking moment you shot. J-cut in."),
            .init(title: "Build", summary: "Sequence supporting footage so each clip raises interest; vary shot sizes; cut clutter."),
            .init(title: "Payoff", summary: "End on the clip that delivers the promise — the reveal, the view, the realization."),
        ],
        "Problem → Solution": [
            .init(title: "Problem", summary: "Open on the pain point fast."),
            .init(title: "Agitation", summary: "Amplify the cost of not solving it."),
            .init(title: "Solution / steps", summary: "Your demo footage, ordered as clear steps."),
            .init(title: "Proof", summary: "The result, transformation, or testimonial you captured."),
            .init(title: "Call to action", summary: "One clear next step."),
        ],
        "Three-act": [
            .init(title: "Setup", summary: "Establish world and goal from your opening footage; the inciting moment."),
            .init(title: "Confrontation", summary: "Rising obstacles; a midpoint turn; stakes climb."),
            .init(title: "Resolution", summary: "Climax and closure; the change lands."),
        ],
        "Kishōtenketsu": [
            .init(title: "Ki — Introduction", summary: "Subject in their normal state."),
            .init(title: "Shō — Development", summary: "Life unfolds; gradual texture."),
            .init(title: "Ten — Twist", summary: "An unexpected shift recontextualizes it."),
            .init(title: "Ketsu — Reconciliation", summary: "Integration; a new perspective settles."),
        ],
        "Story circle": [
            .init(title: "You", summary: "The subject in their comfort zone."),
            .init(title: "Need", summary: "They want something."),
            .init(title: "Go", summary: "They enter an unfamiliar situation."),
            .init(title: "Search", summary: "They adapt and explore."),
            .init(title: "Find", summary: "They get what they wanted."),
            .init(title: "Take", summary: "They pay a price / learn the cost."),
            .init(title: "Return", summary: "Back to the familiar."),
            .init(title: "Change", summary: "Transformed by the journey."),
        ],
        "Before / After": [
            .init(title: "Before", summary: "Establish the starting state (often teased in the hook)."),
            .init(title: "Process", summary: "The journey/method, summarized from your footage."),
            .init(title: "After", summary: "Reveal the transformation."),
            .init(title: "Reflection", summary: "What it meant; the takeaway."),
        ],
    ]

    private static let blocks: [StoryTemplate] = [
        .init(title: "Establishing shot", summary: "Pick a wide clip for context."),
        .init(title: "Detail shot", summary: "A close-up/insert for texture and emotion."),
        .init(title: "Voiceover line", summary: "A retrospective spoken line over the visuals."),
        .init(title: "Title / text card", summary: "On-screen title or chapter card."),
        .init(title: "Music cue", summary: "A musical hit or section change to cut on."),
    ]

    static func recommendedStructure(forDirection title: String) -> String? {
        recommendedByDirection[title]
    }

    static func beats(forStructure title: String) -> [StoryTemplate] {
        beatsByStructure[title] ?? beatsByStructure["Hook → Build → Payoff"]!
    }

    /// Suggested children for a given parent node (nil → top-level directions). For a direction, the
    /// recommended structure is surfaced first and flagged.
    static func childSuggestions(forParent parent: StoryNode?) -> (kind: StoryNodeKind, templates: [StoryTemplate]) {
        guard let parent else { return (.direction, directions) }
        switch parent.kind {
        case .direction:
            let recName = recommendedStructure(forDirection: parent.title)
            var ordered: [StoryTemplate] = []
            if let recName, let rec = structures.first(where: { $0.title == recName }) {
                ordered.append(StoryTemplate(title: rec.title, summary: rec.summary, recommended: true))
            }
            for s in structures where s.title != recName { ordered.append(s) }
            return (.structure, ordered)
        case .structure:
            return (.beat, beats(forStructure: parent.title))
        case .act:
            return (.beat, beats(forStructure: "Three-act"))
        case .beat, .block:
            return (.block, blocks)
        }
    }
}
