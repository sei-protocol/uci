# seidroid review v2

The next generation of the seidroid review: the same bot, identity, markers and review
contract as [`seidroid-review.yml`](../../workflows/seidroid-review.yml), on a simpler
engine. The review runs in [pi](https://pi.dev) on the GitHub runner, so there is no
session server, sandbox or teardown, and every part of it is pinned by one uci ref.

It is in development and runs beside v1 without changing it.

## Layout

| Path | What it is |
|---|---|
| `src/verdict.ts` | The review contract: the `submit_review` schema, and how a submission becomes the recorded decision, check conclusion, placeable findings and thread plan. |
| `src/accepted.ts` | The base branch's accepted pre-existing conditions, read from its guidelines. |
| `test/` | Tests, ported from the v1 driver's. |

## Development

Node 24 runs the TypeScript directly, so there is no build step.

```sh
npm ci
npm run typecheck
npm test
```
