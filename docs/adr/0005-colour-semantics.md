# ADR-0005: Colour has three jobs — identity, interaction, ground

Status: Accepted

## Context

The app was built to a "functional colour only" stance (`design/native-v2/`,
"Pure System + Color"): system blue as the single accent, colour otherwise
reserved for tag dots, priority orbs and the Settings row icons. In practice
all three surfaces — capture box, editor, screenshot picker — read as
greyscale, which is what #101 was filed about.

Investigating turned up a cause that wasn't the palette. A section's hue came
from a DJB2 hash of its name over eight entries, two of which were a grey
(slate) and a blue a shade off the system accent. Over 17 plausible section
names, 9 landed on indigo, blue or slate. The colour was already there; it just
didn't separate anything.

Four directions were mocked at full fidelity in light and dark
(`design/color-directions/`): warmer surfaces, richer section identity,
more vivid interaction moments, and a composite. The middle one was chosen.

## Decision

Colour has exactly three jobs, and nothing borrows across them:

1. **Tag hue = section identity.** A section's hue carries its dot, caption,
   tinted band, rule, indent guides and the checkboxes inside it — and the
   capture box's tag field, which is the same tag. Nothing outside a section
   takes a tag hue.
2. **System blue = interaction.** Focus, selection, links, the vim mode pill,
   and any checked state outside a section.
3. **Neutral = the ground.** Surfaces stay near-monochrome. Warmer surfaces
   were explored and rejected: they read as a yellowed display beside genuinely
   neutral macOS chrome, and they lowered contrast rather than raising it.

Priority orbs and the Settings row icons remain the standing exceptions — they
are functional colour predating this decision, and they are not tag hues.

Two rules follow from the first job:

- **A hue is allocated, not derived.** A section takes the next unused hue the
  first time it is seen and keeps it; the map is persisted. Hashing was stable
  but clustered; assigning by position in the file separates but lets a
  section's colour move when the file is reordered, which is worse than
  clustering. Slate is retired — a grey gives a section no identity.
- **The editor does not decide.** Because the hue is state, Swift owns the map
  and pushes it into the web layer. The two implementations of the hash that
  had to be kept in sync by hand are gone.

## Consequences

- Colour now carries two meanings — identity and interaction — where it carried
  one. The rule above is what keeps them apart; violations will not be obvious
  from a screenshot, so they belong in review.
- The section caption mixes toward the primary ink rather than the secondary
  grey, which makes it *more* legible than the grey it replaced: 5.05–8.52:1
  across the palette, against 3.49:1 light / 5.74:1 dark before.
- The `Theme` tokens are unchanged by this decision. The hue is per-section
  state, not a theme colour — a distinction worth preserving.
- Adding an eighth section reuses a hue. That is accepted: two sections sharing
  a colour far apart in a file is better than seven near-identical ones.
- The picker gains nothing from this direction — it has no sections. If it
  needs life, that is a separate decision.

## Implementation

#102 (assignment), #103 (editor), #104 (capture tag field). Mockups and the
generator that produced them: `design/color-directions/`. Vocabulary:
`CONTEXT.md` under **Tag hue**. Token-level spec: `design/native-v2/HANDOFF.md`
under "Revised by #101".
