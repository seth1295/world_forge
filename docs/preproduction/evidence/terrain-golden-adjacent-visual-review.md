# Golden adjacent terrain visual review — Taste Receptor Atlas v2

- **Paths / budget / sequence:** `terrain-golden-adjacent.webp` (LOD 0) and `terrain-golden-adjacent-lod1.webp` (LOD 1); short edge 512; one static frame per state.
- **Applicable maximum:** 144 points (72 receptors).
- **Score:** 141 / 144 (97.9%) — Grade A.
- **Hard gates:** None.

| Family | Score | Applicable receptor evidence |
|---|---:|---|
| HIER | 8/8 | `WEIGHT-MATH`, `FOVEAL-CLEAR`, `PERIPH-READ`, `SCAN-PATH` = 2 |
| CTRST | 10/10 | `BODY-45`, `LARGE-30`, `PLATE-OPACITY`, `PLATE-EDGE`, `SIMULTANEOUS` = 2 |
| TYPE | 32/32 | `ROLE-TOKEN`, `SCALE-RATIO`, `HUD-FLOOR`, `FACE-CAP`, `DISPLAY-HUD-SPLIT`, `WEIGHT-STEPS`, `XHEIGHT`, `GLYPH-INTEGRITY`, `NUM-LINING`, `NUM-DISTINCT`, `STAT-ALIGN`, `TRACK-BODY`, `LEAD-DENSE`, `CASE-SENTENCE`, `ALLCAPS-BODY`, `PLATE-TYPE` = 2 |
| AFF | 10/10 | `OPERABLE`, `SELECTED`, `HIT`, `CTA-VIS`, `FALSE` = 2 |
| SPACE | 17/18 | `8PT-RHYTHM` = 1; `PROX-CLUSTER`, `REGION-PANEL`, `ALIGN-GRID`, `EDGE-HUD`, `PLAYFIELD`, `DENSITY-BUDGET`, `PANEL-PAD`, `NEST-DEPTH` = 2 |
| COLOR | 13/14 | `ACC-JOB` = 1; `ROLES`, `LAYERS`, `BUDGET`, `ONLY`, `SIM`, `COUNT` = 2 |
| ICON | N/A | No icons are present. |
| COMP | 17/18 | `THIRD-ACTION` = 1; `THIRD-HUD`, `CENTER-CLEAR`, `FOCAL-SINGLE`, `DEPTH-LAYERS`, `NEG-SPACE`, `BALANCE`, `HORIZ-LEVEL`, `SAFE-EDGE` = 2 |
| LIGHT | 10/10 | `MOTIV`, `KEY-FILL`, `PLAY-SEP`, `BLOOM-HIER`, `BLOOM-ABUSE` = 2 |
| MOT | N/A | Static captures only. |
| SLOP | 22/22 | `PURPLE`, `NEON`, `CREAM`, `CARD`, `GLASS`, `HOLO`, `FAKE-TEXT`, `EQUAL`, `BLOOM`, `SPEC`, `STACK` = 2 |
| ORIG | N/A | Real source-derived terrain and a technical overlay; no authored art is being evaluated. |
| ID | 2/2 | `UIWORLD` = 2; no second product surface is shown. |

**Zeroes:** None.

**Ordered fixes:**

1. `SPACE-8PT-RHYTHM=1` — the 22 px panel offset and 15 px internal padding do not fully follow a 4–8 px spacing rhythm.
2. `COLOR-ACC-JOB=1` — teal mostly marks the eyebrow and panel edge; its accent role is limited in this technical view.
3. `COMP-THIRD-ACTION=1` — the Golden relief focal point remains near the center. The same camera is used for both levels, and the LOD change is identified by the overlay rather than exaggerated terrain styling.

Both images show the actual pinned-build viewer and generated terrain, with the selected adjacent tile set and LOD state. At this overview scale the LOD 0 and LOD 1 surfaces look close; the overlay identifies the state and reports LOD 1's observed omitted-sample deviation. The buffer reduction and shared-edge checks are established by automated tests, not inferred from these stills. LOD 1 is visual structural data only: its coarse collision shape is disabled and removed from physics layers, and same-index physics rays prove it cannot be hit. LOD 0 retains source-sampled collision for ground contact.
