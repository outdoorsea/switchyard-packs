nightly-retro: close the day across this city's switchyard projects.

For each active switchyard project (discover them with `list_projects` — do not
assume a fixed list):

- `draft_daily_report` for the project.
- Note completions, validation verdicts, intake arrivals, and error spikes.

Then mail the mayor a 5-line cross-project summary whose last line is the top 3
improvement candidates for tomorrow.

Those candidates are proposals about the SYSTEM, not the product: what wasted
time, what failed silently, what a human had to do twice. They become
`source=retro` intake once the server-side retro lands; until then the mail is
the artifact.

If a project has no activity, say so in one line and move on. An honest empty
retro is worth more than a padded one.
