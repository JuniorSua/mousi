import Foundation

/// Everything Mousi can do to a selection. Each action is one fast, single-output model call.
enum Presentation { case apply, note }

struct MousiAction: Identifiable, Hashable {
    let id: String
    let label: String        // shown on the pill / in the menu
    let icon: String         // SF Symbol
    let hint: String         // tooltip
    let system: String       // system prompt
    var doneVerb: String = "Replaced"
    /// `.apply` puts the result straight into the document; `.note` shows it as a short read-only note.
    var presents: Presentation = .apply
    /// Optional hard word cap, computed from the input length. Models ignore "keep it short" in prose,
    /// so for length-sensitive actions we count the words ourselves and state the number.
    var lengthMult: Double? = nil
    var lengthFloor: Int = 12
    /// Imperative restated *after* the tagged selection in the user turn. A concrete verb matters:
    /// a vague "apply the instructions above" lets the model drift back into answering the text.
    var task: String = "Rewrite the text between the tags above. Output only the rewritten text."

    static func == (a: MousiAction, b: MousiAction) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }
}

enum Actions {
    /// Shared rules appended to every rewrite prompt. Kept short — every token is latency.
    private static let base = """
    Keep the meaning, language, names, numbers and line breaks. Return only the resulting text: \
    no commentary, no preamble, no quotes around it.
    """

    // MARK: Primary

    static let professional = MousiAction(
        id: "professional", label: "Professional", icon: "wand.and.sparkles",
        hint: "Fix grammar and make it clear and professional",
        system: """
        Rewrite the highlighted text so it is correct, clear and professional. Fix every grammar, spelling \
        and punctuation error. Keep it about the same length and keep the writer's own voice — polish it, don't inflate it. \
        \(base)
        """)

    /// Deliberately does *not* open with "correct, clear and professional" the way `professional` does:
    /// sharing that stem made both actions produce near-identical text. Warmth leads, grammar follows,
    /// and the concrete moves matter — "warm and personable" alone reads as an abstraction models ignore.
    static let friendly = MousiAction(
        id: "friendly", label: "Friendly", icon: "hand.wave",
        hint: "Fix grammar and make it noticeably warmer and more personable",
        system: """
        Rewrite the highlighted text so it sounds genuinely warm and human — that is the whole point of \
        this action, so the result must read noticeably friendlier than the original, not merely cleaner. \
        Use contractions, speak to the reader directly as "you", turn blunt statements and demands into \
        considerate requests, and prefer everyday words and short, active sentences. Where the text already \
        supports one, open with a brief human touch such as a thanks or a quick acknowledgement — but never \
        invent gratitude, context or facts the text does not support, and never thank someone for something \
        they did not do. Rewrite whatever you are given, however terse or context-free — a fragment, a \
        complaint, a one-line demand. Never ask for clarification, never say you need more context, and \
        never comment on what the text refers to. Keep the same speaker and the same direction: if the \
        text asks the reader to do something, the rewrite still asks the reader to do it — never flip a \
        demand into an offer to help, and never answer the text as if it were addressed to you. \
        Fix every grammar, spelling and punctuation error along the way. Stay professional: \
        warm, never gushing — do not pile on pleasantries or repeat the same thanks twice, and use no slang, \
        no emoji and no exclamation marks unless the original had them. Running a little longer than the \
        original is fine if the warmth needs the room. \(base)
        """)

    // MARK: Secondary (⋯ menu)

    static let enhancePrompt = MousiAction(
        id: "prompt", label: "Enhance as AI prompt", icon: "lightbulb.max.fill",
        hint: "Rewrite this rough request as a sharper AI prompt",
        system: PromptEnhancer.systemPrompt,
        lengthMult: 2.0, lengthFloor: 20,
        task: "Enhance the request between the tags above. Output only the enhanced prompt.")

    static let shorten = MousiAction(
        id: "shorten", label: "Shorten", icon: "arrow.down.right.and.arrow.up.left",
        hint: "Same message, noticeably shorter",
        system: """
        Rewrite the highlighted text to be significantly shorter — aim for about half the length — while keeping \
        every point that matters and fixing any errors. Cut filler, hedging and repetition, not substance. \(base)
        """,
        lengthMult: 0.6, lengthFloor: 8)

    static let expand = MousiAction(
        id: "expand", label: "Expand", icon: "arrow.up.left.and.arrow.down.right",
        hint: "Add helpful detail and structure",
        system: """
        Rewrite the highlighted text with more useful detail and a clearer structure, roughly 1.5–2× the length. \
        Fix every grammar, spelling and punctuation error. \
        Only develop ideas the text already implies — do not invent facts, names, numbers or claims. \(base)
        """,
        lengthMult: 2.2, lengthFloor: 40)

    static let bullets = MousiAction(
        id: "bullets", label: "Make bullets", icon: "list.bullet",
        hint: "Turn this into a tight bulleted list",
        system: """
        Rewrite the highlighted text as a tight bulleted list ("- " per line), one idea per bullet, in a sensible order. \
        Keep it scannable and fix any errors. Do not add points the text doesn't contain. \(base)
        """)

    static let summarize = MousiAction(
        id: "summarize", label: "Summarize", icon: "text.line.first.and.arrowtriangle.forward",
        hint: "Boil this down to the key points",
        system: """
        Summarize the highlighted text in a few sentences (or short bullets if it covers several distinct points). \
        Lead with the single most important point. Keep only what the text actually says. \(base)
        """,
        doneVerb: "Summarized", lengthMult: 0.45, lengthFloor: 15,
        task: "Summarize the text between the tags above. Output only the summary.")

    static let simplify = MousiAction(
        id: "simplify", label: "Simplify", icon: "text.magnifyingglass",
        hint: "Plain language, no jargon",
        system: """
        Rewrite the highlighted text in plain, direct language a smart non-expert can follow on the first read. \
        Replace jargon with everyday words, shorten sentences, and keep every fact intact. \
        Fix every grammar, spelling and punctuation error. \(base)
        """)

    static let reply = MousiAction(
        id: "reply", label: "Draft a reply", icon: "arrowshape.turn.up.left",
        hint: "Write a reply to this message",
        system: """
        The highlighted text is a message the user received. Write their reply to it: acknowledge the key points, \
        answer what was asked, and close with a clear next step. Match the sender's register — professional and warm, \
        never stiff. Keep it brief. Do not invent facts, commitments, dates or numbers the message doesn't support; \
        keep it general where the user's position is unknown. Return only the reply text, with no subject line, \
        greeting placeholder or sign-off placeholder like [Your name].
        """,
        doneVerb: "Reply drafted")

    static let safetyCheck = MousiAction(
        id: "safety", label: "Before I send…", icon: "shield.lefthalf.filled",
        hint: "Flag anything risky before you send it",
        system: """
        You are a last-second check before the user sends this text. Reply with a very short plain-text review \
        of at most 4 lines, each starting with "- ", covering only things that genuinely matter: \
        secrets or sensitive data (API keys, passwords, tokens, card or account numbers, personal data), \
        an unintended commitment or promise, a tone that could read as rude, dismissive or defensive, \
        and any claim stated as fact that the text itself doesn't support. \
        If nothing is wrong, reply with exactly: Looks good to send. \
        Do not rewrite the text and do not comment on style or grammar.
        """,
        doneVerb: "Checked", presents: .note,
        task: "Review the text between the tags above. Output only the review.")

    /// Actions shown in the ⋯ menu, in order.
    static let more: [MousiAction] = [
        enhancePrompt, reply, shorten, expand, summarize, bullets, simplify, safetyCheck,
    ]

    static let all: [MousiAction] = [professional, friendly] + more

    static func byID(_ id: String) -> MousiAction? { all.first { $0.id == id } }
}
