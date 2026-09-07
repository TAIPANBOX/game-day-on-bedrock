# Game day on Bedrock, as a pipeline gate

Three faults a model provider can throw at an agent, rehearsed against a
gateway whose upstream is a stub the operator controls, with a check that a
person would actually have heard about each one. The job's exit code is the
whole result.

The three scenarios under `scenarios/`:

- `bedrock-throttle.yaml`: the upstream is reachable and answers 429 with the
  documented ThrottlingException shape.
- `bedrock-model-retired.yaml`: the upstream answers 400 for a model id that
  no longer exists.
- `bedrock-region-failover.yaml`: the upstream answers 200 from somewhere other
  than the region the request named.

Each scenario expects a status at the gateway and, for the second step, an
`alert_sent` event from the notifier within 20 seconds.

## What runs

`lib/steps.sh` is the only place the steps live. `.github/workflows/game-day.yml`
sources it on a GitHub-hosted runner; `run-local.sh` sources it on your own
machine. The two differ in two env vars, `BINARY_SOURCE` and `HERALDYX_ENABLED`,
and in nothing else.

- The gateway is TokenFuse, fetched as a release binary and started in enforce
  mode with its upstream pointed at `local/stub.py`.
- The scenarios are run by mockryx, built from source at a pinned commit.
- The notifier is heraldyx, built from source at a pinned commit, writing mail
  to a file instead of sending it.

## Run it

On GitHub: every push to `main` runs it. For the drill that must fail, run the
workflow by hand with `heraldyx_enabled` set to `false`.

Locally, with the three binaries in a directory of your own:

```bash
BINARY_SOURCE=/path/to/binaries ./run-local.sh
HERALDYX_ENABLED=false BINARY_SOURCE=/path/to/binaries ./run-local.sh
```

## What the first runs found

Recorded in the evidence beside the article this repository accompanies: with
the gateway release pinned here, a reachable upstream that answers 429 or 400
is passed through to the caller with the right status, but the gateway emits
no event for it, so the notifier never hears and the reaction check goes red.
The drill is doing its job when it says so. The finding is the gateway's to
fix, and the pipeline will go green on its own when it does.
