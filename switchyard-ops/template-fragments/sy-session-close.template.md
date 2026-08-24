{{/*
  sy-session-close — switchyard-original. The unattended-operation warning,
  shared by every lane that a reconciler starts and a timed order nudges, so
  the rule is stated ONCE and cannot drift between prompts.

  WHAT LIVES HERE, AND WHAT DOES NOT. This fragment carries the invariant:
  nobody is watching the pane, an interactive prompt blocks the turn forever
  and does it silently, and every health surface stays green while it happens.
  It deliberately does NOT carry the one-sentence "and here is how that bites
  YOUR lane" paragraph — that is genuinely per-role (the dupe-scout's pairs,
  the golden-journey's borderline pass, the conductor's ninety-second lease),
  it is the part worth tailoring, and it belongs in the agent prompt directly
  after the include.

  WHY IT WAS EXTRACTED. Nine prompts carried this warning as copy-pasted
  prose and it had already drifted: three different phrasings of the example
  question, and two different line-wrappings of prose that was otherwise
  word-for-word identical. Nothing detected that, because a prompt is never
  diffed against its siblings. Stated once, it cannot happen again.

  WHY THE `sy-` PREFIX. gc loads every imported pack's template-fragments/
  into ONE namespace, so a generic name like "session-close" would be shadowed
  by (or would shadow) an upstream pack's fragment of the same name in a city
  that imports both. That is not a cosmetic risk: when `{{ template }}` names a
  template that is not defined, renderPrompt's Execute fails and returns the RAW
  template body — the agent gets an unrendered prompt with `{{ .RigRoot }}` and
  every other action still in braces, not merely a missing section. The `sy-`
  prefix keeps this fragment resolvable from this pack's own
  template-fragments/ regardless of what else a city imports.

  `{{ cmd }}` BELOW IS A FUNCTION, NOT A FIELD. It resolves from renderPrompt's
  FuncMap, which is set-wide, so it renders inside this define block exactly as
  it does in a prompt body — include the fragment with the dot
  (`{{ template "sy-session-close" . }}`) and it behaves identically.

  Include it from a prompt with a template action naming "sy-session-close",
  exactly as the brakeman prompt includes "tdd-discipline".
*/}}
{{ define "sy-session-close" }}
## You run UNATTENDED — never ask an interactive question

**Nobody is watching your pane.** You are started by a reconciler and nudged by
timed orders; there is no human at a keyboard. An interactive prompt — a
multiple-choice menu, a confirmation, "which of these did you mean?" — blocks
your turn **forever**, and it blocks it *silently*: the session still reads
`active` with a fresh `LAST ACTIVE` (repainting the menu counts as activity),
`{{ cmd }} status` stays clean, orders keep firing `ok:true`, and nothing
anywhere reports an error. A coordinator in this city stalled ~80 minutes
exactly that way — work ready, no workers, every health surface green — until a
human happened to look at the pane.
{{ end }}
