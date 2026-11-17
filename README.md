# Open Payments Elixir Snippets

A developer CLI that exercises the public
[`open_payments_elixir` SDK](https://github.com/interledger/open-payments-elixir).

## Local setup

Keep the SDK checkout next to this project.

```text
interledger/
├── open-payments-elixir/
└── open-payments-elixir-snippets/
```

The project declares Elixir 1.17+ to match the SDK. Local verification currently
uses Elixir 1.20.4 / OTP 29. Minimum-runtime execution remains pending.

```sh
mix deps.get
mix check
mix escript.build
./open-payments help
./open-payments version
./open-payments version --json
```

The local path dependency consumes the sibling SDK's working tree, including
uncommitted changes. This project is under development with that checkout.
Build artifacts and fetched dependencies live in this project's `_build` and
`deps` directories.

The generated `open-payments` escript embeds Elixir and its runtime dependencies.
Running it requires compatible Erlang/OTP. You can invoke it by absolute path
from another directory. See the [Mix escript documentation](https://mix.hexdocs.pm/Mix.Tasks.Escript.Build.html).

## Local wallet settings

Create a local `.env` in this project's root from the placeholder template.

```sh
cp .env.example .env
```

Edit `.env` with your test wallet address, registered signing-key ID, and the path
to your existing unencrypted Ed25519 PKCS#8 PEM private key. The variable names
are `WALLET_ADDRESS`, `KEY_ID`, and `PRIVATE_KEY_FILE`. You can instead set
`PRIVATE_KEY_BASE64` to base64-encoded PEM and remove the file setting.

Git ignores `.env` and its local variants. The tracked `.env.example` contains
placeholders. Keep the private key file outside the repository.

Load your `.env` into the current shell from the project root.

```sh
set -a
. ./.env
set +a
```

`wallet get` and `wallet keys` use the exported `WALLET_ADDRESS` when no address
argument is supplied. These public operations require no signing key. Automatic
`.env` loading remains pending, so load the file into your shell before invoking it.

## Commands and output

| Invocation | Result |
| --- | --- |
| `open-payments`, `open-payments help`, `open-payments --help`, `open-payments -h` | Usage and available commands |
| `open-payments version`, `open-payments --version`, `open-payments -v` | CLI version, SDK version, Open Payments specification version and revision |
| `open-payments version --json` | The same version data as a JSON object |
| `open-payments wallet get [address]` | Fetch and validate public wallet information |
| `open-payments wallet get [address] --json` | Public wallet information with the SDK's JSON field mappings |
| `open-payments wallet keys [address]` | Fetch and validate the wallet's public JWKS, displayed as formatted JSON |
| `open-payments wallet keys [address] --json` | The public JWKS as compact JSON |
| `open-payments incoming get-public <url>` | Fetch public incoming-payment details as formatted JSON |
| `open-payments incoming get-public <url> --json` | Public incoming-payment details as compact JSON |
| `open-payments keys validate` | Validate an existing Ed25519 signing key offline |
| `open-payments keys validate --json` | Validation summary with `valid` and `key_id` fields |
| `open-payments keys public` | Export the configured key's public JWK as formatted JSON |
| `open-payments keys public --jwks` | Export a public JWKS containing that key |
| `open-payments grant validate <file>` | Validate a complete grant-request JSON file offline |
| `open-payments grant validate - --json` | Validate grant-request JSON from stdin and return a summary |

Version JSON keys are `cli_version`, `sdk_version`, `specification_version`, and
`specification_revision`. The SDK supplies the specification metadata. Wallet
JSON uses Open Payments field names such as `assetCode` and `authServer`, and
preserves the SDK's returned extension fields.

Key-set JSON contains a `keys` array of public JWK objects using the SDK's
encoders. Empty sets and duplicate key IDs retain the SDK's supported behavior.

Options accept standard boolean values and negation. `--json` applies to version,
wallet, incoming-payment, key-command, and grant-validation results. Unknown commands, extra arguments, conflicting help/version requests,
and unknown or invalid options produce diagnostics. See the [OptionParser documentation](https://elixir.hexdocs.pm/OptionParser.html).

Results go to stdout. Diagnostics go to stderr. Exit statuses are 0 for success,
1 for operation/runtime failures, and 2 for argument/configuration errors.

## Wallet discovery

Pass a wallet URL or a quoted payment pointer, or use the exported wallet setting.
An explicit address takes precedence over `WALLET_ADDRESS`.

```sh
./open-payments wallet get 'https://wallet.example/alice'
./open-payments wallet get '$wallet.example/alice' --json
./open-payments wallet get --json
```

The SDK resolves payment pointers and validates responses. A root pointer such
as `$wallet.example` uses `https://wallet.example/.well-known/pay`. Returned
authorization and resource-server URLs retain their paths.

Fetch the wallet's registered public keys with `wallet keys`.

```sh
./open-payments wallet keys '$wallet.example/alice'
./open-payments wallet keys --json
```

The SDK resolves the wallet identifier and appends `jwks.json` to its path. A
root pointer such as `$wallet.example` uses
`https://wallet.example/.well-known/pay/jwks.json`. The SDK validates the returned
JWKS and each public JWK. Default output is formatted JSON; `--json` produces
compact JSON for scripts.

For a local development server, explicitly enable HTTP.

```sh
./open-payments wallet get 'http://localhost:3000/accounts/alice' --allow-http
```

HTTP is disabled by default. Discovery uses an unsigned GET. The SDK handles
transport, validation, redirects, and retry policy. HTTP, transport, and invalid
response failures return status 1 with a diagnostic on stderr. Invalid wallet
identifiers and missing configuration return status 2. Diagnostics include the
failure category and HTTP status when available, while server error bodies stay
out of diagnostics.

## Public incoming-payment reads

Use an existing incoming-payment resource URL to fetch its public details.

```sh
./open-payments incoming get-public 'https://payments.example/tenant/incoming-payments/payment-1'
./open-payments incoming get-public 'https://payments.example/tenant/incoming-payments/payment-1' --json
```

The command requires a full resource URL. The SDK preserves its path, query, and
supported port. Wallet payment pointers identify wallets; supply the complete
incoming-payment URL returned when that payment was created. `WALLET_ADDRESS`
provides defaults only for wallet commands.

Reads are unsigned and require no signing key or access token. The SDK handles
HTTP, response decoding, protocol validation, redirects and retries. Local HTTP
requires `--allow-http`. Invalid or missing URLs return status 2. HTTP, transport,
and invalid response failures return status 1 with safe diagnostics on stderr.

Default output is formatted JSON, and `--json` produces compact JSON. Amounts,
timestamps, returned URLs, optional fields, and extensions use the SDK's JSON
representation. Fields named `sharedSecret`, including those nested in
extensions, display `[REDACTED]` in both modes.

## Signing-key validation

Validate an existing unencrypted Ed25519 PKCS#8 PEM key using its file path and
registered key ID.

```sh
./open-payments keys validate --key-file '/absolute/path/to/your-private-key.pem' --key-id 'registered-key-id'
```

After loading `.env` into your shell, use `KEY_ID` with either `PRIVATE_KEY_FILE`
or `PRIVATE_KEY_BASE64`.

```sh
./open-payments keys validate
./open-payments keys validate --json
```

`PRIVATE_KEY_BASE64` contains base64-encoded PEM text. Empty environment values
count as unset. If both environment key sources are populated, the command
returns a configuration error. `--key-file` selects a file for the current
invocation and takes precedence over the environment key sources. `--key-id`
takes precedence over `KEY_ID`. These flags apply to `keys validate` and `keys public`.

The SDK performs key import and validation. Success returns status 0 and shows
the key ID. JSON output contains `valid: true` and `key_id`. Missing or invalid
configuration returns status 2 with a diagnostic on stderr. Output omits private
key material and file paths. This offline check requires no wallet address or
server.

## Public signing-key export

Export public registration data from the configured signing key.

```sh
./open-payments keys public
./open-payments keys public --json
./open-payments keys public --jwks --json
```

`keys public` uses the same `KEY_ID`, PEM file/base64 settings, and flag overrides
as `keys validate`. The SDK imports the existing key, derives its public data,
and encodes the exported JWK or JWKS. Output contains the public fields `kid`,
`alg`, `kty`, `crv`, and `x`. The `--jwks` option wraps the JWK in a `keys` array.
Default output is formatted JSON, and `--json` produces compact JSON. This
operation runs offline and writes the result to stdout.

## Grant-request validation

Check a complete grant-request payload through the SDK's request model. A minimal
request for quote creation access has this shape.

```json
{
  "client": "https://wallet.example/alice",
  "access_token": {
    "access": [{"type": "quote", "actions": ["create"]}]
  }
}
```

Save the JSON in a file and pass its path, or supply JSON on stdin with `-`.

```sh
./open-payments grant validate '/absolute/path/to/grant-request.json'
cat '/absolute/path/to/grant-request.json' | ./open-payments grant validate - --json
```

The SDK checks client identity, nested access/interaction/subject data and request
variants. Supply the complete payload, including its client identity. This is an
offline validation step and requires no signing-key configuration or server.

Success returns status 0 with `Valid grant request`, or `{"valid":true}` when
`--json` is selected. File-read, JSON, schema and argument failures return status
2 with diagnostics on stderr. Schema errors include the SDK's field paths and
constraint messages. Payload values stay out of results and diagnostics.

## Development

```sh
mix test
mix format --check-formatted
mix compile --warnings-as-errors
```

After fetching dependencies, the test suite runs offline and uses a local HTTP
server for wallet and public incoming-payment tests. `OpenPaymentsSnippets.CLI.run/1` returns
the exit status for callers and tests. The executable entry point `main/1`
terminates the VM with that status.
