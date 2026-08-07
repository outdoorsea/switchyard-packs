{{/*
  sy-review-findings — switchyard-original. Shared by the judge and by any
  future review guidance in this pack, so the ordering rule and the confidence
  floor are stated ONCE and cannot drift between reviewers.

  WHY THE `sy-` PREFIX. gc loads every imported pack's template-fragments/ into
  ONE namespace, so a generic name like "review-findings" would be shadowed by
  (or would shadow) an upstream pack's fragment of the same name in a city that
  imports both. That is not a cosmetic risk: when `{{ template }}` names a
  template that is not defined, renderPrompt's Execute fails and returns the RAW
  template body — the reviewer gets an unrendered prompt with `{{ .RigRoot }}`
  and every other action still in braces, not merely a missing section. The
  `sy-` prefix keeps this fragment resolvable from this pack's own
  template-fragments/ regardless of what else a city imports. Same hazard the
  vendored tdd-discipline fragment documents; opposite remedy, because that one
  is a deliberate copy of an upstream file and this one is ours.

  Include it from a prompt with a template action naming "sy-review-findings",
  exactly as the brakeman prompt includes "tdd-discipline".
*/}}
{{ define "sy-review-findings" }}
## Reporting what you found

A judgment is one verdict, but a verdict usually rests on more than one
observation. Each observation you write down is a **finding**, and there are two
kinds. They are not equal, and treating them as equal is how a review buries the
thing that mattered under the things that did not.

- An **acceptance finding** names a clause of the acceptance criterion that the
  delivery does not satisfy. It is the reason a verdict is what it is. If a
  criterion says "with no second copy of the restart logic" and there are two,
  that is an acceptance finding.
- A **quality finding** is true of the code but **not required by the
  criterion** — naming, structure, duplication, a slow path, a test that could
  be tighter, a comment that has gone stale. It may well be worth saying. It is
  never the reason for a verdict.

**Acceptance findings are reported first — all of them, before any quality
finding.** Write them at the top of the `rationale`, in the order the criterion
states its clauses, so a reader walking the criterion top to bottom meets your
findings in the same order. Quality findings follow, clearly after, and never
interleaved. A reader who stops after the first paragraph must still have read
everything that bears on the verdict.

This ordering is not a courtesy. The rework agent reads your rationale to decide
what to change. A quality finding sitting above an acceptance finding gets fixed
first and sometimes gets fixed *instead*.

### The confidence floor, and what it is anchored to

Report a finding only when it clears the floor. **The floor is anchored to the
citation bar the verdict itself must clear** — not to a percentage, and not to
how sure you feel. Concretely, a finding is above the floor when you can produce
both of these:

1. **A concrete code location you actually read** — the same
   `path:line-range` you would be willing to put in `code_locations`. The server
   refuses a `judgment` verdict whose `code_locations` are empty (400), so this
   is the identical standard, applied one level down: if a finding could not
   survive being cited, it is not reportable.
2. **The thing it is anchored to.** For an acceptance finding, the **clause of
   the criterion** it fails, quoted. For a quality finding, the **concrete
   consequence** — the input, state, or change that would make it bite.

A finding that has one but not the other is below the floor. "This feels
over-engineered" has no location; "line 42 is odd" has no consequence. Suppress
both. Say nothing rather than spend a rework agent's attention on an observation
you could not anchor — an unanchored finding reads exactly like an anchored one
to whoever has to act on it, which is precisely what makes it expensive.

### The floor governs findings, never the verdict

**Suppressing a finding must never soften a verdict.** These are different acts
and the floor applies to only one of them.

If an acceptance finding is below the floor, you do **not** suppress it and post
`done`. A criterion you suspect is unmet but cannot yet cite is unfinished
reading, not a passing delivery. Go read the code that would settle it. If it
then clears the floor, report it and `fail`. If you genuinely cannot settle it,
**decline** — post nothing.

This is the same rule as **"a false `done` is far worse than a slow queue"**,
seen from the reporting side. The floor exists to keep low-value findings out of
a rationale. It never converts "I am not sure this is satisfied" into "this is
satisfied."
{{ end }}
