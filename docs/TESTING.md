# Reusable acceptance tests

The committed tests and results contain synthetic wallet addresses or currency
roles. Configure real addresses and signing settings locally at runtime. Public
reports retain amounts, currencies, SDK versions, counts and verification outcomes.
They omit wallet addresses, payment/grant/key IDs, tokens, callbacks, run IDs,
account names, raw responses and local file paths.

## Offline checks

```sh
mix check
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s scripts/tests -v
elixir scripts/check_consumer.exs --offline
elixir scripts/check_consumer.exs --sdk-path ../open-payments-elixir --offline
```

`mix check` includes the full CLI suite and five Web Monetization flows using
public RFC 8032 keys and loopback providers. The isolated consumer also tests the
built production executable. It clears operational credentials before testing.

The Python 3.9+ runner checks exercise orchestration and the report boundary
without contacting a provider. They cover paced contributions, exact token reuse,
cap validation, normal-payment verification, cleanup, missing callbacks, private
file modes, durable attempts, and refusal to replay failed or completed runs.
CI runs these checks without loading wallet settings or issuing live payments.

## Opt-in live checks

The [live runner](../scripts/live_scenarios.py) uses the built CLI for all SDK
operations. `init` creates resources and requests authorization. `resume` can send
payments within the selected recipe's bounds. These actions run only when invoked
explicitly; normal CI never invokes them.

Build the executable, then prepare local settings:

```sh
mix escript.build
cp examples/live-tests.env.example .env.live
```

Fill the ignored `.env.live` with the EUR/GBP wallet addresses and callback URIs.
Keep signing configuration in your existing ignored `.env`. Wallet pointers or
canonical addresses are accepted. Both currency wallets must have scale 2. The
stream recipe currently uses the signing client's authorization server for both
grants, so its sender and receiver must share that server. Normal macro scenarios
support separate authorization servers.

The [scenario recipes](../examples/live-scenarios.json) contain only role names
and documented numeric parameters. Use a new state directory for each scenario:

```sh
python3 scripts/live_scenarios.py init \
  --scenario hourly-stream --state-dir .live-tests/hourly-01 \
  --env-file .env --env-file .env.live
```

The runner creates an owner-only directory and protected state files under the
ignored `.live-tests/` tree. Read its `next-step-*.json` file for the provider
consent URL. Complete consent and save the full returned callback URL as a private
file, such as `.live-tests/hourly-01/callback.txt`, with mode 600. Manual address-bar
copying works even without a local callback web server. The SDK verifies the
saved destination, query parameters and callback hash before continuation.

```sh
python3 scripts/live_scenarios.py resume \
  --state-dir .live-tests/hourly-01 \
  --callback-file .live-tests/hourly-01/callback.txt
```

A normal scenario may stop at receiver consent and then sender consent. Resume
once with each stage's callback. If initialization reaches quote readiness, resume
without `--callback-file` to confirm and create the outgoing payment. Signing
settings supplied to `init` are retained as private file references for subsequent
invocations; the runner does not copy the signing key into its state directory.

After delivery checks pass, the runner completes the stream's incoming payment,
revokes both resource tokens, and cancels both grants. Each outgoing attempt is
recorded before invoking the CLI. A failed/interrupted run retains private state
for reconciliation and is never automatically replayed. A whole-run lock prevents
concurrent resumes; do not remove a stale lock or attempt marker without first
reconciling the recorded operation.

Export the checked, allowlisted summary to a shareable file:

```sh
python3 scripts/live_scenarios.py report \
  --state-dir .live-tests/hourly-01 > test-results/my-hourly-run.json
```

Only the `report` output and sanitized final result are intended for sharing.
Keep the operational state, environment files, consent URLs and raw diagnostics
local. `.gitignore` excludes `.live-tests/`, local `.env` variants and the private
implementation plan.

## Numeric parameters and recorded outcomes

Values are integer strings in minor units: scale 2 means 100 minor units per
major currency unit. Money arithmetic uses integers throughout. The normal
receive amounts below were randomly chosen during the original live run and are
now fixed recipe inputs for reproducibility. The maximum debit is an authorization
cap, not an amount the test automatically spends.

| Scenario | Receive target | Maximum sender debit | Observed debit on 2026-11-24 |
| --- | ---: | ---: | ---: |
| `eur-to-eur` | EUR16.31 (`1631`) | EUR100.00 (`10000`) | EUR17.31 (`1731`) |
| `gbp-to-gbp` | GBP76.34 (`7634`) | GBP100.00 (`10000`) | GBP76.34 (`7634`) |
| `eur-to-gbp` | GBP75.69 (`7569`) | EUR100.00 (`10000`) | EUR90.89 (`9089`) |
| `gbp-to-eur` | EUR61.42 (`6142`) | GBP100.00 (`10000`) | GBP51.16 (`5116`) |

Observed debits include the provider's fees and exchange rates for that run. A
future run obtains a fresh quote and validates its cap and binding; it does not
assert a historical exchange rate or increase the cap automatically. Received
amounts, settlement, metadata equality and token/grant cleanup must still pass.

The `hourly-stream` recipe uses a GBP10.00 (`1000`) budget per hourly interval
(`R/<fresh UTC start>/PT1H`) and sends eight GBP0.01 (`1`) contributions using
one grant and the exact same access token. Total expected debit/receipt is GBP0.08
(`8`), leaving GBP9.92 (`992`) before cancellation. The budget renews hourly until
the grant is cancelled; it is independent from token expiry and contribution size.
The minimum start spacing is 3.6 seconds, equivalent to 10.00/hour at one minor
unit per contribution. Delivery verification can make actual spacing longer.
The bounded test finishes after eight payments and cancels its grant. It does not
wait an hour or test budget renewal at the hour boundary.

The original hourly run settled all eight payments over 46.684 seconds between
first and last starts, with at least 6.576 seconds between starts. Its predecessor
was a separate three-contribution check with a GBP0.03 cap that verified token
rotation and cleanup. Those three payments are recorded as an ancillary check;
the eight-payment test is the hourly-budget acceptance result.

The [sanitized baseline](../test-results/2026-11-24.json) records 15 settled outgoing
payments across these runs, with total actual debits EUR108.20 and GBP127.61.
SDK/test metadata was verified on every incoming/outgoing resource. All test
tokens were revoked, grants cancelled, and callback receivers stopped. The portable
runner is validated offline; this historical baseline comes from the previously
executed live scenarios and is not a claim that a new live run occurred while
saving the runner.

The recorded SDK is Hex 1.0.0 and sibling source release `bf97d71`. Both passed
373 runner tests, 8 executable smoke tests and 11 executable flows on Linux
Elixir/OTP 1.17.3/26, 1.19.7/28 and 1.20.5/29, plus macOS 1.20.4/29. Synthetic
scale-9 sub-cent scenarios are simulated. Hosted CI was not dispatched for that
baseline. These bounded scenarios do not claim exhaustive provider behavior or
browser DOM monetization-event coverage.
