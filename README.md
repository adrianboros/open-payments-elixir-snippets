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
| `open-payments incoming get <url>` | Fetch authenticated incoming-payment details with a signed resource-token request |
| `open-payments incoming get <url> --access-token-file <path> --json` | Read a resource token from a file and display redacted compact JSON |
| `open-payments incoming create <file\|->` | Discover the receiving wallet's resource server and submit one signed creation request |
| `open-payments incoming complete <url>` | Mark an incoming payment complete using one signed POST |
| `open-payments incoming list [address]` | Discover a wallet and fetch one signed page of incoming payments |
| `open-payments quote get <url>` | Fetch quote details using one signed resource-token request |
| `open-payments quote create <file\|->` | Discover the sending wallet's resource server and submit one signed quote request |
| `open-payments keys validate` | Validate an existing Ed25519 signing key offline |
| `open-payments keys validate --json` | Validation summary with `valid` and `key_id` fields |
| `open-payments keys public` | Export the configured key's public JWK as formatted JSON |
| `open-payments keys public --jwks` | Export a public JWKS containing that key |
| `open-payments grant validate <file>` | Validate a complete grant-request JSON file offline |
| `open-payments grant validate - --json` | Validate grant-request JSON from stdin and return a summary |
| `open-payments grant request <file\|-> --output <path>` | Discover the authorization server, request a signed grant, and save private session state |
| `open-payments pointer resolve <pointer>` | Convert a quoted payment pointer to a URL offline |
| `open-payments pointer resolve <pointer> --json` | Return the resolved URL in a JSON `url` field |

Version JSON keys are `cli_version`, `sdk_version`, `specification_version`, and
`specification_revision`. The SDK supplies the specification metadata. Wallet
JSON uses Open Payments field names such as `assetCode` and `authServer`, and
preserves the SDK's returned extension fields.

Key-set JSON contains a `keys` array of public JWK objects using the SDK's
encoders. Empty sets and duplicate key IDs retain the SDK's supported behavior.

Options accept standard boolean values and negation. `--json` applies to version,
wallet, incoming-payment, quote, key-command, grant, and pointer results. Unknown commands, extra arguments, conflicting help/version requests,
and unknown or invalid options produce diagnostics. See the [OptionParser documentation](https://elixir.hexdocs.pm/OptionParser.html).

Results go to stdout. Diagnostics go to stderr. Exit statuses are 0 for success,
1 for operation/runtime failures, and 2 for argument/configuration errors.

## Payment-pointer conversion

Resolve a payment pointer through the SDK's pure conversion helper.

```sh
./open-payments pointer resolve '$wallet.example'
./open-payments pointer resolve '$wallet.example/alice' --json
```

The pointer argument is required. Keep the single quotes around `$...` so your
shell preserves it. Root pointers resolve to `https://wallet.example/.well-known/pay`.
Other paths retain the SDK's spelling and percent encoding.

Default output is the resolved URL followed by a newline. JSON output contains
a `url` field. Missing or invalid pointers return status 2 with safe diagnostics
on stderr. This conversion runs offline and requires no environment settings.

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
incoming-payment URL returned when that payment was created. This public read
requires no wallet environment setting.

Reads are unsigned and require no signing key or access token. The SDK handles
HTTP, response decoding, protocol validation, redirects and retries. Local HTTP
requires `--allow-http`. Invalid or missing URLs return status 2. HTTP, transport,
and invalid response failures return status 1 with safe diagnostics on stderr.

Default output is formatted JSON, and `--json` produces compact JSON. Amounts,
timestamps, returned URLs, optional fields, and extensions use the SDK's JSON
representation. Fields named `sharedSecret`, including those nested in
extensions, display `[REDACTED]` in both modes.

## Authenticated incoming-payment reads

Use `incoming get` for the SDK's authenticated response, which includes the
wallet address and detailed payment fields. Supply the full incoming-payment
resource URL, the signing settings above, and an issued **resource access token**
with read permission for that payment. Continuation and token-management
credentials serve different operations; the server verifies permissions,
expiry and key binding.

```sh
./open-payments incoming get 'https://payments.example/tenant/incoming-payments/id' \
  --access-token-file '/absolute/private/directory/resource-token.txt'
./open-payments incoming get 'https://payments.example/tenant/incoming-payments/id' \
  --access-token-file '/absolute/private/directory/resource-token.txt' --json
```

The token file contains only the opaque token value, without `GNAP`, quotes or
JSON. A single trailing LF or CRLF is accepted; other whitespace is validated by
the SDK. Keep the file outside Git with owner-only permissions. Alternatively,
load `ACCESS_TOKEN` into your shell environment. `--access-token-file` overrides
the environment value, including when the file is missing or invalid. Token
values are not accepted as command-line flags.

For an immediately approved `grant request`, the issued resource token is saved
at `response.access_token.value`. Use a grant allowing incoming-payment `read`
access. A pending consent response's `response.continue.access_token.value` is a
continuation credential and cannot authorize this read. The CLI does not yet
extract tokens from grant-session files or continue pending grants.

`WALLET_ADDRESS`, `KEY_ID`, and one explicit private-key source configure the
authenticated client. `--wallet-address`, `--key-id`, and `--key-file` override
their defaults. Wallet URLs and quoted payment pointers are supported as the
client identity; the payment URL remains an explicit resource URL. This command
performs no wallet discovery and does not infer a resource path from the wallet.

The SDK sends one signed GET with `Authorization: GNAP <token>` and no request
body. Paths and queries retain their spelling. HTTPS is required unless
`--allow-http` is supplied for local development. Redirects and automatic retries
are disabled. The SDK validates the detailed response, payment methods and asset
consistency. It does not create or complete a payment.

Default output is formatted JSON and `--json` produces compact JSON. Both modes
replace every `sharedSecret` field with `[REDACTED]`, including nested metadata
and extension data. Other fields use the SDK's wire representation, preserving
decimal amount strings and timestamp spelling. Request tokens, private keys,
file paths and server error bodies stay out of diagnostics. Missing or invalid
inputs return status 2; HTTP, transport, signing and response failures return 1.

## Incoming-payment creation

Create a receiving-payment resource with `incoming create`. Supply a JSON file
or `-` for stdin, your signing settings, and an issued resource access token with
incoming-payment `create` permission for the receiving wallet's resource server.

```json
{
  "walletAddress": "https://wallet.example/receiver",
  "incomingAmount": {"value": "1000", "assetCode": "USD", "assetScale": 2},
  "metadata": {"description": "Example payment"}
}
```

Only `walletAddress` is required. `incomingAmount`, `expiresAt` (an RFC 3339
timestamp) and JSON-object `metadata` are optional. The SDK validates the schema;
explicit nulls and unknown top-level fields are rejected. Amount values are
decimal strings. Use assets supported by the receiving wallet; the server
enforces compatibility and grant permissions.

```sh
./open-payments incoming create '/absolute/path/to/incoming-request.json' \
  --access-token-file '/absolute/private/directory/create-token.txt'
cat '/absolute/path/to/incoming-request.json' | ./open-payments incoming create - \
  --access-token-file '/absolute/private/directory/create-token.txt' --json
```

`ACCESS_TOKEN` and `--access-token-file` follow the same precedence and file-format
rules as authenticated reads. Use a resource token with creation permission;
continuation and token-management credentials belong to other operations.
`WALLET_ADDRESS`, `KEY_ID` and one private-key source identify the signing client,
with `--wallet-address`, `--key-id` and `--key-file` overrides available.

The explicit payload `walletAddress` selects the **receiving wallet** and must
be a full wallet URL. It can differ from the configured signing wallet. The
command validates the JSON and client configuration, discovers the receiving
wallet using an unsigned GET, then delegates a signed POST to the SDK using its
returned `resourceServer`. The SDK appends `/incoming-payments`, preserving tenant
paths and an existing trailing slash. A resource-server base URL containing a
query is rejected. Local HTTP requires `--allow-http` for both requests.
The payload wallet, amount, expiry and metadata are sent as supplied.

HTTP 201 returns the new payment's details with ILP `sharedSecret` fields
recursively redacted. Default output is formatted JSON; `--json` produces compact
JSON. The SDK validates the response, including completed false, zero received
funds, required methods and consistent assets. Results retain the SDK's field
names, amount strings, timestamps and other supported data.

Missing/invalid input or configuration returns status 2. Discovery, HTTP, signing,
transport and invalid-response failures return status 1 with safe diagnostics.
No automatic retry, redirect or follow-up read occurs. A transport or invalid
response failure after the POST can leave a payment created on the server;
review the outcome before manually submitting another creation request.

## Incoming-payment completion

Mark an existing incoming payment complete using its full resource URL and a
resource access token with incoming-payment `complete` permission.

```sh
./open-payments incoming complete 'https://payments.example/tenant/incoming-payments/id' \
  --access-token-file '/absolute/private/directory/complete-token.txt'
./open-payments incoming complete 'https://payments.example/tenant/incoming-payments/id' \
  --access-token-file '/absolute/private/directory/complete-token.txt' --json
```

Signing settings, `ACCESS_TOKEN`, token-file precedence and key/wallet overrides
follow the same rules as authenticated incoming reads. The resource URL is
required; it is not inferred from `WALLET_ADDRESS`. The SDK appends `/complete`,
preserving tenant/opaque paths and reusing a trailing slash. URLs with queries,
including an empty `?`, are rejected. Local HTTP requires `--allow-http`.

The command sends one signed POST with no request body or wallet discovery.
HTTP 200 returns detailed payment JSON with `completed: true`. The SDK checks
the completion response and asset consistency; the server decides eligibility
and checks permissions. The CLI adds no requirement that the full incoming
amount has already been received.

Default output is formatted JSON and `--json` produces compact JSON. Amounts,
timestamps and supported metadata use SDK wire mappings. Completion responses
exclude payment methods; any nested `sharedSecret` fields are still redacted.
Input/configuration failures return status 2 and operation failures return 1,
with credentials, paths and server error bodies omitted from diagnostics.
No retry, redirect or automatic readback occurs. A transport or invalid-response
failure may follow successful completion on the server; review the outcome
before manually repeating the command.

## Incoming-payment listing

Fetch one page with a resource access token granting incoming-payment `list`
permission. The optional address accepts a wallet URL or quoted payment pointer.
When omitted, it defaults to the configured signing wallet (`--wallet-address`
over exported `WALLET_ADDRESS`). An explicit list address selects the wallet to
discover without changing the signing client.

```sh
./open-payments incoming list --first 10 \
  --access-token-file '/absolute/private/directory/list-token.txt'
./open-payments incoming list '$wallet.example/receiver' --last 10 \
  --cursor 'opaque-cursor' --access-token-file '/absolute/private/directory/list-token.txt' --json
```

The command discovers that wallet unsigned, then uses its returned ID as the
wallet filter and its `resourceServer` as the collection base. The SDK appends
`/incoming-payments`, encodes `wallet-address` and pagination arguments, and signs
the complete GET URL. Tenant paths and trailing slashes are preserved. A base
URL containing a query is rejected; local HTTP requires `--allow-http`.

`--first` and `--last` are mutually exclusive integer counts from 1 through 100.
`--cursor` is an opaque nonempty string, preserved and encoded by the SDK. It can
be supplied alone or with a count. No page size, direction or cursor is defaulted
when flags are omitted. Pagination flags apply only to `incoming list`.

The result contains SDK `pagination` metadata and a `result` array. Empty pages,
item order and duplicates are retained. Default output is formatted JSON;
`--json` produces compact JSON. Nested `sharedSecret` fields in metadata,
amount extensions or the page wrapper are recursively redacted. Other data,
including cursors, decimal amount strings and timestamps, keeps the SDK's wire
representation. The SDK validates every detailed item and its amount assets.

Only one page is fetched, even when `hasNextPage` is true. Choose the next cursor
and direction explicitly for a subsequent invocation. Signing settings, token
sources and overrides use the same rules as other authenticated incoming
commands. Input/configuration/pagination errors return status 2; HTTP, transport,
signing and invalid-response failures return 1 with safe diagnostics. Redirects
and automatic retries remain disabled.

## Quote reads

Fetch an existing quote with its full resource URL and an issued resource access
token granting quote `read` permission.

```sh
./open-payments quote get 'https://payments.example/tenant/quotes/id' \
  --access-token-file '/absolute/private/directory/quote-token.txt'
./open-payments quote get 'https://payments.example/tenant/quotes/id' \
  --access-token-file '/absolute/private/directory/quote-token.txt' --json
```

Use `WALLET_ADDRESS`, `KEY_ID` and one explicit private-key source for the signing
identity. `--wallet-address`, `--key-id` and `--key-file` override their defaults.
`ACCESS_TOKEN` and `--access-token-file` follow the same precedence, raw file
format and single-line-ending rules as authenticated incoming commands.
Supply a resource token for this operation; continuation and token-management
credentials serve other operations. Token values are not accepted as flags.

The quote URL is required. The command performs one signed GET with no body or
wallet/receiver discovery, preserving the URL's opaque path, query and supported
port. The configured wallet supplies the signing identity. HTTPS is required
unless `--allow-http` is provided for local development. Redirects and automatic
retries are disabled.

The SDK validates the quote response and both required amounts. Default output
is formatted JSON and `--json` produces compact JSON using SDK field names,
including `debitAmount` and `receiveAmount`. Different assets are supported.
Decimal spelling, timestamps, wallet/receiver references and optional expiry
string data are preserved. No local fee, exchange-rate or expiry inference is
added. Nested `sharedSecret` fields in amount extensions are redacted.

Missing/invalid URL, credentials or token files return status 2. HTTP, transport,
signing and invalid-response errors return status 1 with safe diagnostics,
omitting request tokens, private keys, file paths and server error bodies.

## Quote creation

Create a quote from a JSON file or stdin using a resource access token granting
quote `create` permission on the sending wallet's resource server.

```json
{
  "walletAddress": "https://wallet.example/sender",
  "receiver": "https://payments.example/tenant/incoming-payments/receiver",
  "method": "ilp",
  "debitAmount": {"value": "1000", "assetCode": "USD", "assetScale": 2}
}
```

`walletAddress`, `receiver` and `method` are required. Supply one of
`debitAmount` or `receiveAmount` for a fixed-debit or fixed-receive quote.
Omitting both requests an amount inferred by the server from the receiver's
incoming payment. At most one amount is allowed. Amount values are decimal
strings; explicit nulls and unknown top-level fields are rejected by the SDK.

```sh
./open-payments quote create '/absolute/path/to/quote-request.json' \
  --access-token-file '/absolute/private/directory/create-quote-token.txt'
cat '/absolute/path/to/quote-request.json' | ./open-payments quote create - \
  --access-token-file '/absolute/private/directory/create-quote-token.txt' --json
```

Signing and token settings use the same rules as quote reads, including
`ACCESS_TOKEN`, file precedence and key/wallet overrides. The explicit payload
`walletAddress` selects the sending wallet for discovery and must be a full
wallet URL. It can differ from the configured signing identity; `--wallet-address`
changes that identity without rewriting the payload.

The command validates the payload and client configuration, discovers the
sending wallet unsigned, then asks the SDK to POST to its `resourceServer` with
`/quotes` appended. Tenant paths and trailing slashes are preserved. Base URLs
with queries are rejected. Local HTTP requires `--allow-http`. The receiver and
amount fields are sent as supplied; receiver lookup, amount availability, asset
compatibility and permission checks belong to the server.

HTTP 201 returns a typed quote, displayed with the same SDK fields, decimal
strings, optional expiry data and nested shared-secret redaction as quote reads.
Default output is formatted JSON; `--json` produces compact JSON.

Input/configuration/SDK validation failures return status 2; HTTP, transport,
signing and invalid-response failures return 1 with safe diagnostics. Creation
makes one signed POST after discovery, with no automatic retry, redirect or
readback. A transport or invalid-response failure can occur after the server
created a quote; review the outcome before manually submitting another request.

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
takes precedence over `KEY_ID`. These flags apply to key commands and authenticated
requests.

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

## Signed grant requests

Submit a complete payload in the same format as `grant validate`, including its
`client` identity. Load the wallet and signing settings described above, then use
a new output file outside the repository.

```sh
./open-payments grant request '/absolute/path/to/grant-request.json' \
  --output '/absolute/private/directory/grant-session.json'
cat '/absolute/path/to/grant-request.json' | ./open-payments grant request - \
  --output '/absolute/private/directory/another-session.json' --json
```

`WALLET_ADDRESS` selects the wallet used for discovery and signing configuration;
`--wallet-address` overrides it and accepts a URL or quoted payment pointer.
`KEY_ID` and one of `PRIVATE_KEY_FILE` or `PRIVATE_KEY_BASE64` supply the registered
signing key. `--key-id` and `--key-file` have the same precedence as key commands.
These settings do not rewrite the payload's explicit client identity.

The command validates the payload and configuration, then creates the output file
exclusively and sets permissions to `0600` before making any requests. Its parent
directory must already exist. Existing files and symlinks are rejected. Keep
this file private and outside Git: it contains the full SDK grant response,
including continuation and issued access tokens, plus versioned context for
future continuation (wallet/key IDs, exact grant endpoint, response receipt time
and requested finish callback). It never contains the private signing key or a
copy of the complete request payload.

Wallet discovery is an unsigned GET. The SDK sends one signed POST to the exact
discovered `authServer` URL, preserving its tenant path and query. Local HTTP
requires `--allow-http`. Redirects and automatic retries are disabled.

Success returns status 0 for both pending consent and immediate approval. Text
output reports `Grant pending` or `Grant approved`; `--json` returns only
`{"status":"pending","saved":true}` or its approved equivalent. Both modes
keep tokens, response extensions and callback nonces out of stdout. For a pending
redirect interaction, the consent link is at `response.interact.redirect` inside
the saved file. The command does not open the link or verify/continue callbacks.
Grant continuation, cancellation and token commands are subsequent increments.

Argument/configuration errors return status 2; HTTP, transport, response-decoding
and session-file failures return status 1. Diagnostics omit payload values,
key paths, tokens and server error bodies. Failed operations remove the newly
created file. A transport, decoding or post-response save failure can happen after
the server created a grant; review that outcome before submitting another request.

## Development

```sh
mix test
mix format --check-formatted
mix compile --warnings-as-errors
```

After fetching dependencies, the test suite runs offline and uses a local HTTP
server for wallet, incoming-payment, quote and grant integration tests. `OpenPaymentsSnippets.CLI.run/1` returns
the exit status for callers and tests. The executable entry point `main/1`
terminates the VM with that status.
