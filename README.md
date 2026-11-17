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

`wallet get` uses the exported `WALLET_ADDRESS` when no address argument is
supplied. This public operation requires no signing key. Automatic `.env`
loading remains pending, so load the file into your shell before invoking it.

## Commands and output

| Invocation | Result |
| --- | --- |
| `open-payments`, `open-payments help`, `open-payments --help`, `open-payments -h` | Usage and available commands |
| `open-payments version`, `open-payments --version`, `open-payments -v` | CLI version, SDK version, Open Payments specification version and revision |
| `open-payments version --json` | The same version data as a JSON object |
| `open-payments wallet get [address]` | Fetch and validate public wallet information |
| `open-payments wallet get [address] --json` | Public wallet information with the SDK's JSON field mappings |

Version JSON keys are `cli_version`, `sdk_version`, `specification_version`, and
`specification_revision`. The SDK supplies the specification metadata. Wallet
JSON uses Open Payments field names such as `assetCode` and `authServer`, and
preserves the SDK's returned extension fields.

Options accept standard boolean values and negation. `--json` applies to version
and wallet results. Unknown commands, extra arguments, conflicting help/version requests,
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

## Development

```sh
mix test
mix format --check-formatted
mix compile --warnings-as-errors
```

After fetching dependencies, the test suite runs offline and uses a local HTTP
server for wallet discovery tests. `OpenPaymentsSnippets.CLI.run/1` returns
the exit status for callers and tests. The executable entry point `main/1`
terminates the VM with that status.
