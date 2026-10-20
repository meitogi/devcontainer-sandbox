# Model rendering — `{{model_line}}`, `{{model_line_short}}`, `{{tier_legend}}`, `{{subagents_block}}`

> Part of `/prepare-plan` — read on demand by the branch that renders this
> file. Substitute every `{{placeholder}}` before writing ; the skill's
> placeholder check enforces zero leftovers.

Always tier + full fallback ladder — never a bare model ID. `fable` is
written resolved (`fable-5.1` or `fable-5`, per the availability gate),
and an absent model is never written at all. Three parts, in order :

1. The Model line (tier gets `*` if classifier gate fired) :

   ```
   > **Model : Tier B — opus-5.5** (fallback : opus-5 → opus-4.8 → opus-4.7 → sonnet-5). Run /model before pasting this prompt.
   ```

   or, gate fired :

   ```
   > **Model : Tier B* — opus-4.8** (fallback : opus-4.7 → sonnet-5, classifier-free set locked). Run /model before pasting this prompt.
   ```

2. For tiers **A/B only**, the degraded-mode sentence :

   ```
   > If running on a fallback model : keep the spec literal and explicit, and add an independent Sonnet sub-agent verification pass before the DoD.
   ```

3. For ALL tiers, the self-check gate block :

   ```
   **Model self-check (first action, before any work)** : check the model
   you are running on (named in your system prompt) against this
   session's tier.
   - Primary, rank-tied with it, or above : proceed silently.
     `opus-5.5`, `opus-5` and `opus-4.8` are rank-tied — any of them
     satisfies a tier A/B primary, whichever the Model line names.
     **Exception — a tier marked `*`** : the rank tie is void there.
     `fable` and the Opus 5.x pair are excluded by the classifier gate, not by
     rank ; on either of them, treat yourself as below the ladder.
   - In the fallback ladder, below the primary's rank : proceed,
     applying the degraded-mode directives.
   - Below the ladder : do NO work yet — ask via AskUserQuestion :
     (1) "I'll switch — /model <primary> now, then I reply 'go'"
         (Recommended) ;
     (2) "Continue anyway on <current model>" (degraded-mode directives
         apply).
     If (1) : end your turn telling the user to run /model <primary> and
     reply "go". On their next message, RE-RUN this self-check — /model
     applies to the next turns of the same session. Still below the
     ladder → ask again (the switch didn't happen). Never start work on
     the user's word alone ; the re-check is the proof.
     If work was already started below the ladder (missed gate), do NOT
     switch in place — fresh chat + /model + re-paste this prompt (it is
     self-contained).
   ```

## `{{model_line_short}}` and `{{tier_legend}}`

- `{{model_line_short}}` — one line, no /model sentence, no gate (for
  STATUS files) : `Tier B — opus-5.5 (fallback : opus-5 → opus-4.8 → opus-4.7 → sonnet-5)`.
  Add `*` after the tier letter if the classifier gate fired.
- `{{tier_legend}}` — one line per **distinct tier used** in the file
  (never all four unconditionally). If any listed tier carries `*`, add
  a final line explaining the marker :

  ```
  Model tiers used here :
  - **A*** = opus-4.8 (fallback : opus-4.7 → sonnet-5)
  - **B** = opus-5.5 (fallback : opus-5 → opus-4.8 → opus-4.7 → sonnet-5)
  - **C** = sonnet-5 (fallback : opus-4.7)
  - `*` suffix = classifier-sensitive session ; classifier-free set locked (Fable and the Opus 5.x pair dropped, opus-4.8 primary).
  ```

  The `*` explainer line appears **only if** at least one tier in the
  file uses it.

## `{{subagents_block}}` (shared by prompt-body and session templates)

```
Sub-agents :
- Exploration / localisation / inventory → fan-out of **Haiku** agents
  (never the main tier for grep work).
- Independent end-of-session verification → one **Sonnet** agent.
- Next-session prompt scaffolding → one **Opus** agent, regardless of
  this session's tier — a session prompt is a planning artifact. The
  main session reviews the draft against the filesystem, then links it.
- Synthesis and decisions stay in the main session — never delegated.
- Note : Bash permissions do not propagate to sub-agents — pre-grant in
  `settings.local.json` if the fan-out needs Bash.
```
