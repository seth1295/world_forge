# Runtime visual review

## Capture scope

The two reviewed files are actual viewport captures from the pinned Windows Godot build after each real bundle completed its asynchronous load. Agent Vision `asset` mode encoded them at a 512-pixel short edge from 1280 × 720 PNGs. The scene uses a plain diagnostic technical overlay, a flat material and the generated terrain mesh; the captures contain no terminal or editor chrome.

| Artifact | Site and anchor | Capture pose (local terrain frame, metres) | Result |
|---|---|---|---|
| [`terrain-baltimore.webp`](terrain-baltimore.webp) | Baltimore, `39.28995370377841 N, 76.60995370372139 W` | Camera `(-503.20670857749536, 28.0, -699.0378389103332)`, looking at `(-846.6239912655444, 32.63882255554199, -1079.4178551042073)`, up `(0,1,0)` | Technical panel is readable and the low-relief terrain is visible, though its relief reads subtly at overview distance. |
| [`terrain-golden.webp`](terrain-golden.webp) | Golden / Front Range, `39.754953704278655 N, 105.21995370310027 W` | Camera `(-1198.3306255951975, 118.5, 904.5941632146123)`, looking at `(-1714.2119027677074, 364.36767578125, 1099.8264649481891)`, up `(0,1,0)` | Technical panel is readable; source-derived ridge relief is clearly visible. |

Both use the same 58° vertical FOV, 0.5 m near plane, 8,000 m far plane, 16:9 aspect and `look_at(target, Vector3.UP)` orientation. Coordinates in this table are site-local mesh coordinates, not global positions. The scene does not exaggerate relief or add imagery. A closer Baltimore camera was tried on the real mesh but did not show clearer relief, so only the wide Baltimore image is retained.

## Taste Receptor Atlas v2

Main Lead scored the two overview images together. Of 237 Atlas receptors, 72 apply to this static technical UI; the possible score is 144 points. The result is **141/144 (97.9%), Grade A**, with no hard gates and no zero scores. Family totals and non-2 scores are:

| Family | Score | Applicable receptor detail |
|---|---:|---|
| HIER | 8/8 | `WEIGHT-MATH`, `FOVEAL-CLEAR`, `PERIPH-READ`, `SCAN-PATH`: 2 each. |
| CTRST | 10/10 | `BODY-45`, `LARGE-30`, `PLATE-OPACITY`, `PLATE-EDGE`, `SIMULTANEOUS`: 2 each. |
| TYPE | 32/32 | `ROLE-TOKEN`, `SCALE-RATIO`, `HUD-FLOOR`, `FACE-CAP`, `DISPLAY-HUD-SPLIT`, `WEIGHT-STEPS`, `XHEIGHT`, `GLYPH-INTEGRITY`, `NUM-LINING`, `NUM-DISTINCT`, `STAT-ALIGN`, `TRACK-BODY`, `LEAD-DENSE`, `CASE-SENTENCE`, `ALLCAPS-BODY`, `PLATE-TYPE`: 2 each. |
| AFF | 10/10 | `OPERABLE`, `SELECTED`, `HIT`, `CTA-VIS`, `FALSE`: 2 each. |
| SPACE | 17/18 | `8PT-RHYTHM` = 1; `PROX-CLUSTER`, `REGION-PANEL`, `ALIGN-GRID`, `EDGE-HUD`, `PLAYFIELD`, `DENSITY-BUDGET`, `PANEL-PAD`, `NEST-DEPTH` = 2. |
| COLOR | 13/14 | `ACC-JOB` = 1; `ROLES`, `LAYERS`, `BUDGET`, `ONLY`, `SIM`, `COUNT` = 2. |
| ICON | N/A | No icon set is present. |
| COMP | 17/18 | `THIRD-ACTION` = 1; `THIRD-HUD`, `CENTER-CLEAR`, `FOCAL-SINGLE`, `DEPTH-LAYERS`, `NEG-SPACE`, `BALANCE`, `HORIZ-LEVEL`, `SAFE-EDGE` = 2. |
| LIGHT | 10/10 | `MOTIV`, `KEY-FILL`, `PLAY-SEP`, `BLOOM-HIER`, `BLOOM-ABUSE`: 2 each. |
| MOT | N/A | Static one-frame evidence; motion receptors do not apply. |
| SLOP | 22/22 | `PURPLE`, `NEON`, `CREAM`, `CARD`, `GLASS`, `HOLO`, `FAKE-TEXT`, `EQUAL`, `BLOOM`, `SPEC`, `STACK`: 2 each. |
| ORIG | N/A | Real terrain/technical fixture rather than authored art. |
| ID | 2/2 | `UIWORLD` = 2; there is no second product surface to compare. |

There are no zeroes. The nonblocking follow-ups, in order, are:

1. `SPACE-8PT-RHYTHM = 1`: if the layout is revised, align the 22 px outer offset and 15 px panel padding to a clearer 4–8 px spacing rhythm.
2. `COLOR-ACC-JOB = 1`: teal currently marks the eyebrow and panel border; no change is needed for this technical view.
3. `COMP-THIRD-ACTION = 1`: Golden relief is clear while Baltimore remains subtle at the wide camera distance. Keep the current overview pair as truthful source evidence.

This is a static visual score, not a product-wide UI audit. It does not assess keyboard/gamepad access, scene-switch interaction, motion, performance or adjacent terrain behavior.