# Approved shoot sources

Drop the post-produced originals here, exactly under these names (they are
kept as delivered and never overwritten):

- `smiling_athlete_on_cardio_machine.png`      → About Coach Gari
- `muscular_athlete_s_dumbbell_front_raise.png` → Book a session (personal training)
- `athletic_twist_in_a_tropical_city_gym.png`   → Online coaching (movement)
- `Zimbabwe_Bird.svg`                           → the origin signature next to "Zimbabwe to Dubai"

Then: `npm i --no-save sharp && node scripts/build-images.mjs` writes the web
derivatives to `assets/img/shoot/` (AVIF + WebP at 640 / 960 / 1280 where the
source allows, a JPEG fallback) and copies the SVG to `assets/img/zimbabwe-bird.svg`.
`node scripts/check-links.mjs` then proves every `srcset` candidate resolves.
Nothing else from this shoot goes on the homepage.
