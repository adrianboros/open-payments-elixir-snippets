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

The project declares Elixir 1.17+ to match the SDK. Isolated consumer verification
covers Linux Elixir/OTP pairs 1.17/26, 1.19/28 and 1.20/29. The macOS development
runtime is Elixir 1.20.4 / OTP 29. See the verification details below.

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

Load your `.env` explicitly for each command (the file is never loaded automatically):

```sh
./open-payments wallet get --env-file .env
./open-payments wallet keys --env-file .env
./open-payments keys validate --env-file .env
```

Alternatively, load it into the current shell from the project root.

```sh
set -a
. ./.env
set +a
```

`wallet get` and `wallet keys` use the exported `WALLET_ADDRESS` when no address
argument is supplied. These public operations require no signing key.
Environment-file loading is opt-in: use `--env-file .env` or load it into your shell.

## Commands and output

| Invocation | Result |
| --- | --- |
| `open-payments`, `open-payments help`, `open-payments --help`, `open-payments -h` | Usage and available commands |
| `open-payments version`, `open-payments --version`, `open-payments -v` | CLI version, SDK version, Open Payments specification version and revision |
| `open-payments version --json` | The same version data as a JSON object |
| `open-payments input render <file\|-> [--env-file <path>] [--var NAME=value]` | Preview a JSON template with resolved values, without HTTP |
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
| `open-payments outgoing get <url>` | Fetch outgoing-payment details using one signed resource-token request |
| `open-payments outgoing create <file\|->` | Discover the sending wallet's resource server and submit one signed payment request |
| `open-payments outgoing list [address]` | Discover a wallet and fetch one signed page of outgoing payments |
| `open-payments outgoing grant-spent-amounts [address]` | Discover a resource server and read the presented token's current grant spent amounts |
| `open-payments quote create <file\|->` | Discover the sending wallet's resource server and submit one signed quote request |
| `open-payments keys validate` | Validate an existing Ed25519 signing key offline |
| `open-payments keys validate --json` | Validation summary with `valid` and `key_id` fields |
| `open-payments keys public` | Export the configured key's public JWK as formatted JSON |
| `open-payments keys public --jwks` | Export a public JWKS containing that key |
| `open-payments grant validate <file>` | Validate a complete grant-request JSON file offline |
| `open-payments grant validate - --json` | Validate grant-request JSON from stdin and return a summary |
| `open-payments grant request <file\|-> --output <path>` | Discover the authorization server, request a signed grant, and save private session state |
| `open-payments grant continue <session>` | Continue once using saved continuation credentials and update the private session |
| `open-payments grant verify-callback <session> --callback-file <path\|->` | Check a callback URL and hash offline without continuing or changing the session |
| `open-payments grant cancel <session>` | Cancel using saved continuation credentials and mark the private session cancelled |
| `open-payments token rotate <session>` | Rotate the issued access token and save its replacement in the private grant session |
| `open-payments token revoke <session>` | Revoke the issued access token and remove it from the private grant session |
| `open-payments payment start <file\|-> --output <path>` | Discover sender and receiver wallets and save initial receiver authorization |
| `open-payments payment prepare <session>` | Create one incoming payment with the saved receiver grant and retain its private result |
| `open-payments payment authorize <session> <file\|->` | Request sender authorization with a debit limit bound to the saved incoming payment |
| `open-payments payment quote <session>` | Create one fixed-receive quote using the saved sender grant and retain its private result |
| `open-payments payment finish <session>` | Confirm and create one outgoing payment from the saved quote |
| `open-payments payment finish <session> --yes --json` | Explicitly approve outgoing creation for automation and return its saved result |
| `open-payments payment initialize <file\|-> --output <path>` | Run discovery and payment setup through consent or quote readiness |
| `open-payments payment finalize <session\|->` | Resume consent and run remaining steps through confirmed outgoing creation |
| `open-payments pointer resolve <pointer>` | Convert a quoted payment pointer to a URL offline |
| `open-payments pointer resolve <pointer> --json` | Return the resolved URL in a JSON `url` field |

Version JSON keys are `cli_version`, `sdk_version`, `specification_version`, and
`specification_revision`. The SDK supplies the specification metadata. Wallet
JSON uses Open Payments field names such as `assetCode` and `authServer`, and
preserves the SDK's returned extension fields.

Key-set JSON contains a `keys` array of public JWK objects using the SDK's
encoders. Empty sets and duplicate key IDs retain the SDK's supported behavior.

Options accept standard boolean values and negation. `--json` applies to version,
wallet, incoming-payment, quote, key-command, grant, pointer, and rendered-input results. Unknown commands, extra arguments, conflicting help/version requests,
and unknown or invalid options produce diagnostics. See the [OptionParser documentation](https://elixir.hexdocs.pm/OptionParser.html).

Results go to stdout. Diagnostics go to stderr. Exit statuses are 0 for success,
1 for operation/runtime failures, and 2 for argument/configuration errors.

## Example files and scenario parameters

The tracked [examples](examples/) contain JSON templates for the payment macros,
individual staged inputs, incoming payments, quotes, outgoing payments and grants.
Payment templates label `metadata.description` with `Open Payments via Elixir SDK`
and the scenario name. Use a fresh initialization to apply updated example metadata.
Prepare a separate local scenario file alongside your existing wallet credentials:

```sh
cp examples/scenarios.env.example .env.scenarios
```

Edit the local values to match the wallets and callbacks you control. If a local
`.env.scenarios` already exists, keep it and update the needed fields. The root
`.env.scenarios` is ignored by Git. Signing settings stay in `.env`.
`WALLET_ADDRESS` identifies the client that owns the signing key. An optional
`sender` field in `payment start` and `payment initialize` selects the paying
wallet independently; it defaults to the signing client wallet when omitted.
The sender owner authorizes the outgoing grant. This lets one registered client
key exercise payments in both directions without replacing its identity.

`--env-file` is repeatable. Later files override earlier files, exported shell
values override files, and existing command flags override their corresponding
settings. Files contain literal `NAME=value` assignments, optional `export`, blank
lines and comments. Single or double quotes preserve their contents. Shell
expressions, variable interpolation, escape sequences and multiline values are
not evaluated; quote a payment pointer such as `'$wallet.example/alice'` literally.
No environment values are changed in the calling shell.

A JSON reference `{"$var": "RECEIVE_VALUE"}` inserts one string value, so amounts
remain integer strings. `{"$var": "WALLET_ASSET_SCALE", "type": "integer"}` inserts
an integer. References work inside objects and arrays; ordinary strings remain
literal. Values are inserted after JSON parsing, preserving quotes, dollar signs
and Unicode. Missing variables and invalid types fail before HTTP. Known signing
credential and access-token settings cannot be rendered into payloads.

Use `--var NAME=value` to override a payload variable for one invocation. It takes
precedence over files and shell variables; repeated values use the last one.
These overrides apply to JSON inputs and do not change signing configuration.
They are accepted by `input render`, `grant validate/request`, resource creation,
`payment start/authorize`, and `payment initialize`.

The finish URI is chosen **before** requesting a grant. For manual local testing,
you can use `http://localhost:3000/callback?stage=receiver` and a separate
`?stage=sender` URI. After approval, the authorization server redirects to that
URI with `hash` and `interact_ref` appended. If no local server is running, the
browser may show a connection error; copy the complete URL from its address bar
into your callback file. Pass that file to `payment finalize --callback-file`.
Keep the original finish URI in the saved session unchanged. The CLI verifies
the returned URL and hash against it. Each interactive grant has its own callback.

For a self-payment preview, set `WALLET_ASSET_CODE` and `WALLET_ASSET_SCALE` from
`wallet get`, plus `RECEIVER_FINISH_URI` and `SENDER_FINISH_URI` in `.env.scenarios`:

```sh
./open-payments input render examples/payment-self.json \
  --env-file .env --env-file .env.scenarios \
  --var RECEIVE_VALUE=1 --var MAX_DEBIT_VALUE=2
```

This renders JSON without making an HTTP call. `1` means one smallest asset unit
(for EUR scale 2, EUR 0.01); `MAX_DEBIT_VALUE` is the sender grant's debit limit,
including room for any fees. The provider determines available routes and fees.
Use values appropriate to your test, and inspect the rendered intent first.

The same template can run directly, without saving a rendered copy:

```sh
./open-payments payment initialize examples/payment-self.json \
  --env-file .env --env-file .env.scenarios \
  --var RECEIVE_VALUE=1 --var MAX_DEBIT_VALUE=2 \
  --output '/absolute/private/directory/self-session.json' --json
```

This creates real grants and payment setup resources. Resume pending consent with
the saved session and returned callback. When it reaches quote readiness, inspect
the quote before finalization:

```sh
./open-payments payment finalize '/absolute/private/directory/self-session.json' \
  --env-file .env --callback-file '/absolute/private/directory/callback.txt'
# Once consent is complete, omit --callback-file; finalization prompts before sending.
./open-payments payment finalize '/absolute/private/directory/self-session.json' \
  --env-file .env
```

Use `payment-cross-wallet.json` for a different receiver. Set its address, asset
code and scale in `.env.scenarios`. Both macros handle separate receiver/sender
consent. Initialization requires a fresh output path for each scenario.

| File | Command | Required scenario data |
| --- | --- | --- |
| `payment-self.json` | `payment initialize` | Sender asset, receive value, maximum debit, both callbacks; receiver uses `WALLET_ADDRESS` |
| `payment-cross-wallet.json` | `payment initialize` | Sender/receiver addresses and assets, amounts and callbacks |
| `payment-start.json` | `payment start` | Sender/receiver addresses, receiver asset/value, receiver callback |
| `sender-authorization.json` | `payment authorize <session>` | Sender asset, maximum debit, sender callback |
| `incoming-payment.json` | `incoming create` | Receiver wallet URL/asset and receive value |
| `quote.json` | `quote create` | Sender wallet URL, incoming-payment URL, receiver asset/value |
| `outgoing-payment.json` | `outgoing create` | Sender wallet URL and quote URL |
| `grant.json` | `grant validate` or `grant request` | Canonical signing-client wallet URL |

Low-level payload fields named `walletAddress` or `client` require absolute wallet
URLs; use the canonical `id` returned by `wallet get` for `SENDER_WALLET_URL`,
`RECEIVER_WALLET_URL` and the signing identity's `CLIENT_WALLET_URL`. Macro receiver inputs accept payment pointers. Resource
creation commands need their correctly scoped `ACCESS_TOKEN` or token file;
macros use the tokens issued to their private session. Rendering checks JSON and
variables; operation commands and `grant validate` perform SDK validation.

### Running both directions with one signing client

Keep `WALLET_ADDRESS` and the matching key in `.env`. Direction-specific local
files such as `.env.gbp-to-eur` and `.env.eur-to-gbp` set
`SENDER_WALLET_ADDRESS`, `SENDER_ASSET_CODE`, `SENDER_ASSET_SCALE`, the receiver
address/asset, `RECEIVE_VALUE`, and both finish URIs. They must not override the
signing client's `WALLET_ADDRESS`. Use the `payment-cross-wallet.json` template.
For example, receive value `125` means EUR 1.25 in the first direction and GBP
1.25 in the reverse direction when both asset scales are 2. A GBP debit cap of
12000 means GBP 120; choose a separate EUR cap for the reverse scenario.

```sh
SESSION_DIR="$(mktemp -d)"
./open-payments payment initialize examples/payment-cross-wallet.json \
  --env-file .env --env-file .env.gbp-to-eur \
  --output "$SESSION_DIR/gbp-to-eur.json"

printf 'Maximum EUR debit in cents: '
IFS= read -r EUR_CAP_MINOR
./open-payments payment initialize examples/payment-cross-wallet.json \
  --env-file .env --env-file .env.eur-to-gbp \
  --var "MAX_DEBIT_VALUE=$EUR_CAP_MINOR" \
  --output "$SESSION_DIR/eur-to-gbp.json"
```

Initialization stops at consent or quote readiness. Open a returned consent URL,
approve it, then capture the full localhost redirect URL. To resume the first
scenario (use `eur-to-gbp.json` for the reverse):

```sh
umask 077
printf 'Paste the full localhost callback URL: '
IFS= read -r CALLBACK_URL
printf '%s\n' "$CALLBACK_URL" > "$SESSION_DIR/callback.txt"
./open-payments grant verify-callback "$SESSION_DIR/gbp-to-eur.json" \
  --callback-file "$SESSION_DIR/callback.txt"
./open-payments payment finalize "$SESSION_DIR/gbp-to-eur.json" \
  --env-file .env --callback-file "$SESSION_DIR/callback.txt"
```

If another consent URL is returned, repeat with its new callback. If initialization
already returned a quote, run `payment finalize` on that session without
`--callback-file`. Finalization shows the quote and asks you to type `send` before
outgoing creation. These commands execute provider calls when you run them.

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
  "metadata": {"description": "Open Payments via Elixir SDK"}
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
when flags are omitted. Pagination flags apply to `incoming list` and `outgoing list`.

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

## Outgoing-payment reads

Fetch an existing outgoing payment using its full resource URL and an issued
resource access token granting outgoing-payment `read` permission:

```sh
./open-payments outgoing get 'https://payments.example/tenant/outgoing-payments/id' \
  --access-token-file '/absolute/private/directory/outgoing-token.txt'
./open-payments outgoing get 'https://payments.example/tenant/outgoing-payments/id' --json
```

The second example uses exported `ACCESS_TOKEN`. Signing settings and file-token
precedence match quote reads: `WALLET_ADDRESS`, `KEY_ID` and one private-key source,
with `--wallet-address`, `--key-id` and `--key-file` overrides. Tokens are never
accepted as literal command-line arguments. The target URL is required; the
configured wallet supplies the signing identity, without replacing that URL.

The SDK signs one bodyless GET to the exact opaque path and query, with no wallet,
quote or receiver discovery. HTTPS is required unless local HTTP is explicitly
enabled with `--allow-http`. No redirect, retry, polling or payment creation occurs.

Default output is formatted JSON; `--json` produces compact JSON with SDK field
names. All three required amounts, decimal spellings, timestamps, optional
`quoteId`/`failed` fields and metadata are preserved. Nested `sharedSecret` values
in amount extensions and metadata are redacted. The SDK validates debit/sent
asset consistency, sent value against debit, and its failed/value-string rule.
The CLI adds no completion, fee, exchange-rate or related-resource inference.

Missing/invalid URL, signing configuration or token sources return status 2.
HTTP, transport, signing and invalid-response failures return 1 with safe
diagnostics and no partial output. Tokens, key paths and server bodies are omitted.

## Outgoing-payment creation

Create an outgoing payment from a complete JSON file or stdin with an issued
resource token granting outgoing-payment `create` permission. Submitting this
command authorizes the server to create and process the payment.

```sh
./open-payments outgoing create '/absolute/path/to/outgoing-request.json' \
  --access-token-file '/absolute/private/directory/outgoing-token.txt'
cat '/absolute/path/to/outgoing-request.json' | ./open-payments outgoing create - --json
```

Use either a quote-based payload:

```json
{
  "walletAddress": "https://wallet.example/sender",
  "quoteId": "https://payments.example/tenant/quotes/id",
  "metadata": {"reference": "invoice-17", "description": "Open Payments via Elixir SDK"}
}
```

Or supply the incoming-payment reference and debit amount directly:

```json
{
  "walletAddress": "https://wallet.example/sender",
  "incomingPayment": "https://receiver.example/tenant/incoming-payments/id",
  "debitAmount": {"value": "100", "assetCode": "USD", "assetScale": 2}
}
```

These forms are mutually exclusive. Metadata is optional; amounts use integer
minor-unit strings. The SDK validates the complete payload before discovery.
The CLI discovers the payload's sending wallet unsigned and uses its
`resourceServer`; the SDK appends `/outgoing-payments` and sends one signed POST.
Tenant paths and trailing slashes are preserved; collection bases with queries
are rejected. No quote or receiver lookup, amount inference or follow-up send/read
request occurs. Local HTTP requires `--allow-http`.

Signing identity and token settings follow outgoing reads. An explicit
`--wallet-address` changes the signing identity without rewriting the payload's
wallet or selecting its resource server. Default output is formatted JSON;
`--json` produces compact SDK JSON. The creation response can already show sent
amounts or failure, and can contain either, both or neither of
`grantSpentDebitAmount` and `grantSpentReceiveAmount`. These grant amounts remain
separate from the payment's amounts. Metadata and permitted extensions are retained;
all nested `sharedSecret` values are redacted.

Input/configuration/schema errors return 2; operation failures return 1 without
partial output, credentials, key paths or server bodies. Redirects and automatic
retries are disabled. A lost or invalid response can follow successful creation
or payment processing; reconcile that outcome before manually repeating the
command, since repetition can create another payment.

## Outgoing-payment listing

Fetch one page with an issued resource token granting outgoing-payment `list`
permission. The optional address accepts a wallet URL or quoted payment pointer;
it defaults to the configured signing wallet. An explicit list address selects
the wallet to discover without changing the signing identity.

```sh
./open-payments outgoing list --first 10 \
  --access-token-file '/absolute/private/directory/outgoing-token.txt'
./open-payments outgoing list '$wallet.example/sender' --last 10 \
  --cursor 'opaque-cursor' --access-token-file '/absolute/private/directory/outgoing-token.txt' --json
```

The command discovers that wallet unsigned and uses its returned ID as the wallet
filter and `resourceServer` as the collection base. The SDK appends
`/outgoing-payments`, encodes the wallet filter and pagination before signing one
bodyless GET. Tenant paths and trailing slashes are preserved. Base URLs with
queries are rejected; local HTTP requires `--allow-http`.

Pagination uses the same rules as incoming listing: choose `--first` or `--last`
(1–100), with an optional opaque nonempty `--cursor`. A cursor alone is supported.
No count, direction or cursor is defaulted. Only one page is fetched, even if
`hasNextPage` is true; choose the next request explicitly.

Output contains SDK `pagination` metadata and an ordered `result` array, retaining
empty pages and duplicates. Default JSON is formatted; `--json` is compact.
Detailed items preserve all three amounts, optional fields and metadata. The SDK
validates every item's schema and debit/sent consistency; invalid pages produce
no partial output. Grant spent amounts belong to creation or the grant-spent
endpoint and are not detailed list-item fields. Nested `sharedSecret` fields in
amounts, metadata or page extensions are redacted.

Signing and resource-token settings follow outgoing reads. Invalid input,
configuration or pagination returns 2; HTTP, transport, signing and response
failures return 1 with safe diagnostics. There is no retry, redirect, automatic
page traversal or related-resource lookup.

## Outgoing grant spent amounts

Read spent amounts for the grant associated with the current issued resource
token. The optional wallet URL or quoted payment pointer selects the resource
server to discover; it defaults to the configured signing wallet.

```sh
./open-payments outgoing grant-spent-amounts \
  --access-token-file '/absolute/private/directory/outgoing-token.txt'
./open-payments outgoing grant-spent-amounts '$wallet.example/sender' --json
```

The second example uses exported `ACCESS_TOKEN`. Signing and token-file settings
follow outgoing reads. An explicit address selects discovery without changing
the signing identity. After unsigned wallet discovery, the SDK appends
`/outgoing-payment-grant` to its `resourceServer` and signs one bodyless GET.
There is no wallet filter, grant ID, payment lookup or pagination. The server
selects the grant and current recurring interval from the presented token.
Resource-server tenant paths and trailing slashes are preserved; base queries are
rejected. Local HTTP requires `--allow-http`.

Default output is formatted JSON; `--json` produces compact SDK JSON. Both
`spentDebitAmount` and `spentReceiveAmount` remain present, each as an amount or
explicit `null`. Decimal spelling, asset data and permitted extensions are
preserved, with nested `sharedSecret` fields redacted. Null is not converted to
zero, and the CLI infers no remaining budget, grant status or interval boundary.

Invalid input/configuration returns 2; HTTP, transport, signing or invalid-response
failures return 1 without partial output or sensitive diagnostics. Pagination,
callback and output-file flags are rejected. No retry, redirect, polling or
related-resource request occurs.

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
the saved file. Use `grant continue` to verify the returned callback and resume.
Use `grant cancel` to cancel the saved grant, `token rotate` to replace an issued
access token, or `token revoke` to revoke it.

Argument/configuration errors return status 2; HTTP, transport, response-decoding
and session-file failures return status 1. Diagnostics omit payload values,
key paths, tokens and server error bodies. Failed operations remove the newly
created file. A transport, decoding or post-response save failure can happen after
the server created a grant; review that outcome before submitting another request.

## Payment macros and JSON pipelines

`payment initialize` and `payment finalize` combine multiple Open Payments steps
to set up and finish a payment quickly. They use a private session to save progress
and resume when wallet consent is required.

Save this combined request as `macro.json`:

```json
{
  "receiver": "$wallet.example/receiver",
  "receiveAmount": {"value": "100", "assetCode": "EUR", "assetScale": 2},
  "finishUri": "https://client.example/return?state=receiver",
  "metadata": {"description": "Open Payments via Elixir SDK - macro payment"},
  "senderAuthorization": {
    "debitAmount": {"value": "200", "assetCode": "USD", "assetScale": 2},
    "finishUri": "https://client.example/return?state=sender"
  }
}
```

The outer fields are the `payment start` input; `sender` and `metadata` are optional. The required
`senderAuthorization` contains the debit limit and callback for `payment authorize`.
Use callback URIs you control. The SDK validates protocol payloads, and the server
enforces grant permissions, limits and quote validity.

```sh
./open-payments payment initialize macro.json \
  --output '/absolute/private/directory/macro-session.json' --json
```

Initialization runs wallet discovery, receiver authorization, incoming creation,
sender authorization and quote creation as far as authorization permits. It stops
at either consent boundary or at `quote-ready`. A pending result contains the
consent URL. The combined intent is saved privately before the first grant request,
so later invocations resume from the recorded stage. Initialization requires a new
output path; it never creates an outgoing payment.

Visit the returned consent URL, then save its full callback URL in a file:

```sh
./open-payments payment finalize '/absolute/private/directory/macro-session.json' \
  --callback-file '/absolute/private/directory/callback.txt'
```

Finalization verifies the callback through the existing grant continuation step,
then runs the remaining setup, quote and outgoing steps. Receiver and sender
consent may require two separate invocations with their respective callbacks.
Without a required callback, it returns the pending descriptor and consent URL
without making a continuation request. A server wait returns `waiting` and
`wait_seconds`; a wait-only continuation stops after one call. Resume explicitly
when ready. Before outgoing creation, type `send` at the preview or use `--yes`.
New JSON-mode outgoing creation requires `--yes`.

JSON results include `scenario: "quote-payment"`, the private `session` path and
`steps` with command/status/save summaries. `saved` reports whether any step saved
progress during that invocation. Tokens, nonces and raw responses stay in the
private session. Each step uses the existing locks, atomic saves and uncertainty
markers; a failed or interrupted mutation requires reconciliation before resuming.
There are no automatic retries or background polling. Repeated successful
finalization returns the saved outgoing result without another submission.

The initializer's JSON descriptor can be piped directly into finalization:

```sh
cat macro.json | ./open-payments payment initialize - \
  --output '/absolute/private/directory/piped-session.json' --json \
  | ./open-payments payment finalize - --yes --json
```

This executes real Open Payments calls against the configured wallets, including
outgoing creation when authorization is ready and `--yes` is supplied. Pending
consent returns a descriptor for a later resume. With a session path argument,
`--callback-file -` reads the callback from stdin. A descriptor and callback cannot
both use stdin; supply one as a file. Normal signing and `--allow-http` settings
apply to each invocation.

| Scenario | Input and behavior |
| --- | --- |
| Self-payment | Set `receiver` to the configured wallet and use its asset; both grants remain separately recorded |
| Cross-wallet or cross-asset payment | Set a different receiver and its receive amount, with the sender's debit limit |
| Interactive authorization | Resume once for each returned consent URL; callbacks remain bound to the correct grant |

The individual staged commands remain available for inspecting and testing each
operation separately. The macros use the same SDK-backed implementations.

## Starting payment authorization

`payment start` begins a payment by discovering both wallets and requesting a
receiver grant with incoming-payment `create` and `read` permissions. This
command stops at receiver authorization. Use `payment prepare` next to create
the incoming payment, then `payment authorize` for sender authorization and
`payment quote` to obtain a quote. Review it and use `payment finish` to create
the outgoing payment.

Save a payment request as JSON:

```json
{
  "receiver": "$wallet.example/receiver",
  "receiveAmount": {"value": "100", "assetCode": "EUR", "assetScale": 2},
  "finishUri": "https://client.example/return?state=your-session-state",
  "metadata": {"description": "Open Payments via Elixir SDK"}
}
```

`receiver`, `receiveAmount` and `finishUri` are required. `sender` and `metadata`
are optional; other fields are rejected. Both wallet inputs accept URLs or payment
pointers. Without `sender`, the signing client wallet is the default payer.
The SDK validates the amount and metadata using its incoming-payment model;
`value` is an integer string in the receiver asset's smallest units. For EUR at
scale 2, `"100"` means EUR 1.00. Supply a callback URI you control, with any session
state included in its query. The CLI generates a fresh 32-byte interaction nonce.

Load your signing settings and choose a new output path in an existing private
directory outside the repository:

```sh
./open-payments payment start '/absolute/path/to/payment-request.json' \
  --output '/absolute/private/directory/payment-session.json'
cat '/absolute/path/to/payment-request.json' | ./open-payments payment start - \
  --output '/absolute/private/directory/another-payment-session.json' --json
```

`WALLET_ADDRESS` identifies the signing client and its registered key's wallet;
`--wallet-address`, `--key-id` and `--key-file` provide the usual overrides.
The optional JSON `sender` field selects the paying wallet independently; both
sender and receiver discovery preserve the client identity. `ACCESS_TOKEN` is unused
and `--access-token-file` is rejected. Local HTTP requires `--allow-http`.

The command performs two unsigned wallet GETs followed by one SDK-signed grant
POST to the receiver's discovered authorization server. Success returns status 0
and reports `pending` or `approved`, stage `receiver-grant`, and the private
session path. Pending consent also returns `consent_url`; visit it to authorize
the grant. `--json` returns these fields with `saved: true`. Tokens, callback
nonces and response extensions remain in the private session.

The session records the validated incoming-payment intent, discovered wallets,
signing identity, callback context and full SDK grant response. The CLI creates
it exclusively with permissions `0600`, uses a sibling lock and saves updates
atomically. Existing files and symlinks are rejected. Use the existing
[`grant continue`](#grant-continuation-and-callbacks) command with the returned
callback to finish authorization, or [`grant cancel`](#grant-cancellation) to
cancel. Continuation preserves the payment intent. An approved grant alone does
not create or send a payment.

Argument/configuration errors return status 2; HTTP and session-file failures
return status 1 with safe diagnostics. Discovery and known preflight failures
remove the unused reservation. Before submitting authorization, the CLI saves
an `in-flight` marker; an ambiguous response leaves the session `uncertain`.
Interrupted attempts can also leave a lock. Reconcile these recorded attempts
before removing a lock or starting again. There are no automatic retries.

## Preparing the incoming payment

After receiver authorization is approved, create its incoming payment using the
private session produced by `payment start`:

```sh
./open-payments payment prepare '/absolute/private/directory/payment-session.json'
./open-payments payment prepare '/absolute/private/directory/payment-session.json' --json
```

For pending authorization, first visit the consent URL and run `grant continue`
with the returned callback as described below. Preparation requires an issued
receiver access token. Continuation credentials cannot replace it. If you rotate
the token with `token rotate`, preparation uses the latest token in the session.
The server enforces its permissions, expiry and signing-key binding.

Wallet and key IDs default to the session's recorded signing client identity, and explicit
overrides must match. Supply the original private key through the usual signing
configuration. `ACCESS_TOKEN` is unused. The command rejects `--access-token-file`,
`--output`, callback and pagination options. Local HTTP requires `--allow-http`.

Preparation validates the saved payment context and calls the SDK once to create
an incoming payment at the saved receiver resource server, using the canonical
wallet ID, receive amount and optional metadata recorded by `payment start`.
It makes no discovery or readback requests. Success saves the full SDK result,
including private ILP details, under `payment.incoming_payment` in the same `0600`
session and advances its stage to `incoming-ready`. Grant response, callback
verification, receipt time and rotated-token context are preserved.

Text output reports readiness, session path and incoming-payment URL. `--json`
returns `status: "ready"`, `stage: "incoming-ready"`, `saved: true`, `session` and
`incoming_payment_url`. Response extensions, metadata, tokens and ILP shared
secrets stay in the private file. Repeating preparation returns the saved URL
with `saved: false`, leaves the file unchanged and makes no request. This is a
saved result; use `incoming get` separately to fetch its current state.

Preparation uses the session's shared lock and records an `in-flight` attempt
before sending the creation request. Known preflight failures restore the ready
session. HTTP, transport or invalid-response failures leave it `uncertain`, and
an interrupted process or save failure can leave an in-flight attempt. Reconcile
these outcomes before any further operation: the server may already have created
the incoming payment. There are no automatic retries. Argument/configuration
failures return status 2; operation/file failures return status 1.

This step creates the receiver's incoming resource. Continue with sender
authorization below, then quote and confirm the outgoing payment.

## Authorizing the sender

After preparation, supply the sender's debit limit and a callback URI in JSON:

```json
{
  "debitAmount": {"value": "200", "assetCode": "USD", "assetScale": 2},
  "finishUri": "https://client.example/sender-return?state=your-sender-state"
}
```

Both fields are required; other fields are rejected. `debitAmount` is the outgoing
grant's debit limit in the sender asset's smallest units. The example requests a
USD 2.00 limit, independently of the receiver's EUR amount. The SDK validates its
amount schema, and the authorization server enforces the granted limit. Supply a
callback URI you control with state for this sender interaction. Each new sender
grant gets a fresh 32-byte nonce.

```sh
./open-payments payment authorize '/absolute/private/directory/payment-session.json' \
  '/absolute/path/to/sender-authorization.json'
cat '/absolute/path/to/sender-authorization.json' | ./open-payments payment authorize \
  '/absolute/private/directory/payment-session.json' - --json
```

The command uses the recorded signing identity and sender authorization server,
with the same key configuration and identity override checks as `payment prepare`.
It makes one signed SDK grant request, without discovery. The requested access is
quote `create`/`read` and outgoing-payment `create`/`read`, with the canonical sender
wallet identifier and limits containing both the explicit debit amount and the
saved incoming-payment URL. `ACCESS_TOKEN` is unused; resource-token, output,
callback and pagination flags are rejected. Local HTTP requires `--allow-http`.

The same private session advances to `sender-grant`. The complete receiver grant
context is retained separately at `payment.receiver_grant`, alongside the incoming
payment and sender authorization input. The active grant fields now hold the
sender endpoint, fresh callback context and sender response. Receiver tokens and
callback verification are retained in the receiver record; they are not used as
sender credentials. The existing `grant continue`, `token rotate`, `token revoke`
and `grant cancel` commands operate on the active sender grant after this step.

Success returns status 0 and reports `pending` or `approved`, stage `sender-grant`,
the session path, and a consent URL when returned. `--json` returns those fields
with `saved: true`. Visit the consent URL for a pending grant, then pass its
returned callback to `grant continue` using the same session. The CLI verifies
that callback against the sender's saved context and honors continuation waits.
Tokens, nonces and full responses remain private.

Repeating `payment authorize` with the same JSON returns the active sender status
with `saved: false` and makes no request or file update. A changed amount or callback
is rejected. After token revocation it reports `revoked` without starting again.
Repeating `payment prepare` still returns its saved incoming-payment result and
preserves the sender stage. Cancelling the active grant replaces the session with
the usual minimal cancellation record, discarding its private flow context.

The shared lock and durable in-flight marker prevent overlapping or replayed
requests. Known preflight failures restore the prepared receiver session. An
ambiguous response leaves the sender attempt `uncertain`, retaining the receiver
record for reconciliation. Interruptions and save failures can leave an in-flight
attempt. There are no automatic retries. Argument/configuration failures return
status 2; HTTP, transport and file failures return status 1 with safe diagnostics.
This command requests authorization. Continue with `payment quote` after approval,
then explicitly confirm outgoing creation with `payment finish`.

## Quoting the saved payment

Once sender authorization is approved, request a quote for the saved receive amount:

```sh
./open-payments payment quote '/absolute/private/directory/payment-session.json'
./open-payments payment quote '/absolute/private/directory/payment-session.json' --json
```

The command uses the saved sender wallet ID, resource server, incoming-payment URL
and original receive amount. It creates one ILP fixed-receive quote using the SDK
and the latest issued sender token, including a replacement saved by `token rotate`.
The debit limit from `payment authorize` remains a grant limit; the quote request
uses `receiveAmount`. The SDK validates the payload and response, and the server
calculates the debit amount, exchange rate and fees.

Signing identity defaults to the session's recorded wallet and key IDs; explicit
overrides must match. Supply the original private signing key through the usual
configuration. `ACCESS_TOKEN` is unused. Resource-token, output, callback and
pagination flags are rejected. Local HTTP requires `--allow-http`. Pending,
wait-only or revoked sender grants cannot create a new quote.

There is one signed POST to the sender's quotes collection, with no discovery or
readback requests. Success saves the full SDK response at `payment.quote` in the
same private `0600` session and advances its stage to `quote-ready`. Sender grant,
callback verification, token rotation, receiver grant and incoming-payment data
are preserved. Earlier preparation and authorization commands can still return
their saved results without changing the quote.

Text output reports the quote URL and debit/receive amounts. `--json` returns
`status: "ready"`, `stage: "quote-ready"`, `saved: true`, `session`, `quote_url`,
`debit_amount` and `receive_amount`. Displayed amounts contain only `value`,
`assetCode` and `assetScale`; additional amount fields remain in the private file.
Repeating the command returns the saved quote with `saved: false`, leaves the file
unchanged and makes no request, including after token revocation. This is a saved
snapshot; expiry data is preserved as returned by the SDK, without automatic
refresh or replacement. A damaged saved quote is rejected.

The shared session lock and durable in-flight marker protect creation. Known
preflight failures restore the original ready sender session. HTTP, transport or
invalid-response failures leave it `uncertain`; interruptions or save failures
can leave an in-flight attempt. Reconcile these outcomes before continuing,
because the server may already have created the quote. There are no automatic
retries. Argument/configuration failures return status 2; operation/file failures
return status 1 with safe diagnostics. This step creates a quote and sends no funds.

## Finishing the payment

Create an outgoing payment from a reviewed, saved quote:

```sh
./open-payments payment finish '/absolute/private/directory/payment-session.json'
```

Before any creation request, text mode shows the sender, incoming-payment and
quote URLs, debit/receive amounts and returned quote expiry on stderr. Type `send`
to confirm. Other input, a blank line or end of input declines; the command returns
status 0 with `Payment not sent` and leaves the session unchanged. The session lock
is held during confirmation so another command cannot change its saved state.

For automation, `--yes` explicitly confirms creation from this saved quote:

```sh
./open-payments payment finish '/absolute/private/directory/payment-session.json' \
  --yes --json
```

New creation with `--json` requires `--yes`, which skips the prompt. The flag is
accepted by `payment finish` and `payment finalize`. Review the saved quote before invoking this
form: it authorizes submission of that outgoing payment. The server enforces quote
validity, grant permissions and limits; the CLI preserves returned expiry data.

The command requires stage `quote-ready` and an issued sender token. It checks that
the saved quote's wallet and receiver match the recorded sender and incoming
payment. The SDK validates a quote-based request containing `walletAddress` and
`quoteId`, then sends one signed POST to the saved sender resource server using
the latest sender token. Before confirmation, the CLI checks the quote against
both the requested debit maximum and a matching outgoing-create permission in the
issued token, including wallet, receiver, asset, scale and amount limits. An
insufficient limit returns status 2 without a prompt, HTTP or session changes.
For example, a quoted debit of 249 cents cannot fit a grant capped at 137 cents.
Changing an environment value does not change a grant already issued: obtain a
new authorization with a suitable cap after reconciling any prior attempt. The
provider still enforces current grant spending, expiry and other permissions.
There are no discovery, quote refresh, readback or polling requests. Signing identity defaults and overrides work as in the other flow steps;
`ACCESS_TOKEN` is unused. Resource-token, output, callback and pagination flags are
rejected. Local HTTP requires `--allow-http`.

Before submitting, the CLI atomically saves an in-flight marker, the exact outgoing
request, confirmation method and confirmation time. A valid creation response is
stored in full at `payment.outgoing_payment` and the stage becomes `outgoing-created`.
Both grants, the incoming payment, quote and rotated-token context remain private
in the same `0600` file. Text output reports the outgoing URL, `failed` and the
debit/receive/sent amounts. JSON returns `status: "created"`, `stage`, `saved`,
`session`, `outgoing_payment_url`, `failed`, `debit_amount`, `receive_amount` and
`sent_amount`. Amount summaries contain only `value`, `assetCode` and `assetScale`;
metadata, grant spent amounts and extensions stay in the private file.

Status 0 means a creation response was recorded, including a response with
`failed: true`. It does not establish delivery or settlement. An omitted SDK
`failed` field appears as JSON null in the summary. Use `outgoing get` separately
for current payment details. Repeating finish returns the saved response with
`saved: false`, without confirmation, HTTP or file updates, even after sender-token
revocation. A failed or damaged saved result never triggers replacement creation.
Earlier prepare, authorize and quote commands still return their saved results.
Cancelling the active grant does not reverse an already created outgoing payment.

Known preflight failures restore the ready quote and require confirmation on a
later attempt. HTTP, transport or invalid-response failures leave the exact attempt
`uncertain`; an interruption or post-response save failure can leave it in-flight.
The outgoing payment may already have been created or started. Reconcile that
outcome before any further action. The CLI makes no automatic retry, and the
saved attempt or stale lock blocks concurrent and repeated submissions.
Argument/configuration failures return status 2; operation/file failures return 1.

## Grant continuation and callbacks

Continue a saved grant using the same private signing key as initiation. Wallet
and key IDs default to the session's recorded identity. Explicit `--wallet-address`
and `--key-id` overrides must match it; the private key still comes from the
existing file/base64 settings or `--key-file`. New sessions also bind the public
JWK. Older version-1 files without that field remain readable; the server checks
the continuation credential's signing-key binding. `ACCESS_TOKEN` and resource
token files are not used for continuation.

For redirect interactions, include a finish callback when requesting the grant:

```json
"interact": {
  "start": ["redirect"],
  "finish": {
    "method": "redirect",
    "uri": "https://client.example/return?state=your-session-state",
    "nonce": "your-fresh-unguessable-ascii-nonce"
  }
}
```

Generate a fresh unpredictable nonce for every request and bind the callback
URI/state to that session. Open the saved consent link yourself. Save the complete
returned callback URL, with its percent encoding intact, in a private text file,
then resume:

```sh
./open-payments grant continue '/absolute/private/directory/grant-session.json' \
  --callback-file '/absolute/private/directory/callback.txt' --json
```

`--callback-file -` reads the URL from stdin. Surrounding whitespace and blank
lines from manual editing are accepted. Paste one complete URL without quotes or
Markdown; line breaks or spaces inside the URL remain invalid. Callback URLs
must match the stored destination and fixed query values,
with exactly one `hash` and `interact_ref`. Error/result fields, unexpected query
values, duplicates and fragments are rejected. The CLI decodes query values once
and asks the SDK to verify the hash against the saved client nonce, server nonce,
interaction reference and exact initial grant endpoint. Copy the complete URL;
manually decoding or rebuilding it can change the hash input.

Before continuing a grant or finalizing a payment, check the callback offline:

```sh
./open-payments grant verify-callback '/absolute/private/directory/grant-session.json' \
  --callback-file '/absolute/private/directory/callback.txt'
```

Success prints `Valid interaction callback` (or `{"valid":true}` with `--json`).
This checks the exact saved destination/query and SDK callback hash with no signing
key, HTTP request, grant continuation or session update. A consumed callback is
rejected. Errors distinguish malformed text, the wrong destination, a different
payment direction/consent stage, missing or duplicate parameters, and hash failure.
The same callback can then be used for `grant continue` or `payment finalize`.

Default `--hash-encoding base64` matches the SDK's deployed Open Payments profile.
For a server using unpadded base64url, explicitly select
`--hash-encoding base64url` together with the callback file. There is no format
fallback. Hash calculation and constant-time verification belong to the SDK.
Endpoint spelling must agree with the server's hash context; a mismatch fails
verification without sending a continuation request.

The command honors the returned `continue.wait` relative to the saved UTC receipt
time. An early invocation returns status 0 with `status: waiting`, `saved: false`
and `wait_seconds`, without sleeping or consuming the callback. Retry explicitly
after that interval. Continuation-only responses can be checked once more with:

```sh
./open-payments grant continue '/absolute/private/directory/grant-session.json' --json
```

Sessions that requested no finish callback, and immediately approved grants, use
a bodyless continuation. A verified callback reference is sent only once. Later
invocations use the latest returned continuation URI and credential with no body.
The SDK signs one POST to that exact URI; no discovery, polling loop, redirect
or automatic retry occurs. Local HTTP requires `--allow-http` again.

The session must be a regular JSON file with permissions `0600` and one filesystem
link. Symlinks and hard links are rejected. Continuation locks the file through
an exclusive sibling `.lock`, records an in-flight attempt before HTTP, and
updates it using a synced private temporary file and atomic rename. Success
stores the latest response and receipt time with state `ready`. Callback replay
and concurrent invocation are rejected. Interruptions can leave an in-flight
record or stale lock; HTTP, transport and invalid-response failures leave state
`uncertain`. Reconcile the server outcome before manually repairing that state
or removing a stale lock. Restoring old file copies can reintroduce old credentials;
use the current session as the authoritative local record.

Stdout contains only status/save summaries, never tokens, callback hashes/nonces,
subject data, file paths or server error bodies. `approved` means an access token
was returned, `subject` means subject-only data, and `pending` means a
continuation-only result. Full results stay in the private file. Expected waiting
and successful results return 0, invalid input/configuration/callbacks return 2,
and operation/locking/write failures return 1. A post-response save failure may
lose the new credentials while retaining an in-flight marker; reconcile before
another attempt.

## Grant cancellation

Cancel an initial or continued grant using its current private session and the
same signing key used for initiation:

```sh
./open-payments grant cancel '/absolute/private/directory/grant-session.json'
./open-payments grant cancel '/absolute/private/directory/another-session.json' --json
```

Wallet/key IDs default to the recorded identity, with matching explicit overrides
and `--key-file` supported as for continuation. The command uses the latest saved
continuation URI and credential. `ACCESS_TOKEN` is ignored; callback, resource
token, pagination and output-file flags are rejected. Pending consent and
`continue.wait` do not delay cancellation, and no callback is required.

The SDK sends one signed, bodyless DELETE to the exact continuation URI with no
discovery, redirect, appended path or automatic retry. Local HTTP requires
`--allow-http`. HTTP 204 confirms success; text reports `Grant cancelled`, while
JSON returns `{"status":"cancelled","saved":true}`. The existing session is
atomically replaced with an owner-only cancellation record containing identity,
public JWK, original grant endpoint and cancellation time. Tokens, callback data,
subject data and response extensions are removed from that file. Both continuation
and repeat cancellation reject the cancelled record. The authorization server
determines cancellation's effect on issued resource tokens; copies of credentials
outside the session are not changed by this command.

Cancellation shares continuation's single-link `0600` file requirement, exclusive
lock, durable in-flight marker and atomic updates. HTTP/transport failures and
unexpected success statuses mark the session uncertain and block further calls.
If saving after HTTP 204 fails, the local record remains in-flight even though
the grant may be cancelled. Reconcile the server outcome before repairing state
or removing a stale lock. Diagnostics omit credentials and server bodies. Exit
statuses are 0 for saved cancellation, 2 for invalid input/configuration, and 1 for
operation, locking or write failures.

## Token rotation

Rotate an issued access token in an approved initial or continued grant session:

```sh
./open-payments token rotate '/absolute/private/directory/grant-session.json'
./open-payments token rotate '/absolute/private/directory/another-session.json' --json
```

Use the same private signing key as initiation. Recorded wallet/key IDs are the
defaults; explicit identity overrides must match, and `--key-file` overrides the
key environment settings. The session must contain a complete issued
`response.access_token`, including its management URI and access list. Pending
and subject-only sessions have no token to rotate. The raw `ACCESS_TOKEN`
environment setting and continuation credentials are not used for rotation.
Resource-token files, callback, pagination and output-file flags are rejected.

The SDK sends one signed, bodyless POST to the token's exact management URI using
that token's value. It performs no discovery, redirect or automatic retry; local
HTTP requires `--allow-http`. HTTP 200 must contain the SDK's token-rotation
response wrapper. On success the CLI atomically replaces
`response.access_token` with the new token, including its new management URI,
access and expiry metadata. The full response and permitted extensions are kept
privately at `token_rotation_response`, with a separate `token_rotated_at` time.
A subsequent rotation uses these latest credentials and replaces that snapshot.

Grant continuation credentials, callback context and the original response receipt
time are preserved, so token rotation does not reset a continuation wait interval.
A later successful grant continuation replaces the grant response and removes the
superseded rotation snapshot. The server determines token invalidation and signing
key binding. Rotation does not change the private signing key, update environment
variables or token files, compare granted scopes, or interpret elapsed expiry.

Text reports `Token rotated`; JSON returns only
`{"status":"rotated","saved":true}`. Tokens, subjects, card data and server
extensions stay in the private file. Rotation shares grant commands' `0600`
single-link file requirement, exclusive lock and durable in-flight/uncertain
markers. Ambiguous failures block further token/grant operations pending
reconciliation; a post-response write failure can lose the replacement token
while retaining the old in-flight record. Exit statuses are 0 for a saved
rotation, 2 for invalid input/configuration, and 1 for operation/file failures.

## Token revocation

Revoke the latest issued token in a private grant session:

```sh
./open-payments token revoke '/absolute/private/directory/grant-session.json'
./open-payments token revoke '/absolute/private/directory/another-session.json' --json
```

Identity, key configuration and private-file requirements are the same as for
rotation. The command reads the current `response.access_token`, including its
management URI and value after any rotation. `ACCESS_TOKEN`, resource-token files
and callback arguments cannot replace it. A pending or subject-only grant has no
issued token to revoke. Continuation wait intervals do not delay revocation.

The SDK sends one signed, bodyless DELETE to the exact management URI and accepts
HTTP 204. Local HTTP requires `--allow-http`; no discovery, redirect or automatic
retry occurs. Text reports `Token revoked`; JSON returns only
`{"status":"revoked","saved":true}`. On success the CLI atomically removes
`response.access_token` and any rotation snapshot from the private file, records
`token_revoked_at`, and changes its kind to `token-revocation`. The session remains
`ready`, retaining grant continuation data, subject data, response extensions and
the original receipt time. Repeat revocation or rotation fails because the issued
token is absent. This operation does not update copies in environment variables,
token files or backups; the server determines revocation's effect.

The grant can still be cancelled or continued using its separate continuation
credential. Continuing honors the original wait interval, can return a new issued
token, and removes the old revocation timestamp when saving that new response.
Token revocation does not cancel the grant.

Revocation uses the shared exclusive session lock and durable in-flight marker.
HTTP/transport failures and unexpected success statuses leave the session
`uncertain` and block further session operations until reconciled. A failure to
save after HTTP 204 leaves the old in-flight record even though the token may be
revoked. No credentials or server bodies appear in diagnostics. Exit statuses are
0 for saved revocation, 2 for invalid input/configuration, and 1 for operation or
file failures.

## Development

```sh
mix test
mix format --check-formatted
mix compile --warnings-as-errors
```

After fetching dependencies, the test suite runs offline and uses a local HTTP
server for wallet, payment, quote, grant and token integration tests.
`OpenPaymentsSnippets.CLI.run/1` returns the exit status for callers and tests.
The executable entry point `main/1` terminates the VM with that status.

The complete-flow tests exercise the existing commands through both quote-based
and direct outgoing payments:

```sh
mix test test/open_payments_snippets/payment_flow_test.exs
```

Each scenario covers discovery, private grant sessions, incoming-payment creation
and reads, callback verification, quote creation/read, token rotation, outgoing
creation/read/list/spent amounts, incoming completion/list, revocation and grant
cancellation. It verifies signatures from received HTTP bytes, rejects a wrong
callback before continuation, checks token-role separation and redaction, and
asserts the exact request count to catch unexpected retries or hidden requests.
All services and payment progress are simulated locally using a public test key;
no provider credentials or funded wallet are required.

The macro tests cover cross-asset payments, self-payments, independent consent
callbacks, server waits, confirmation, saved-step reuse and interrupted operations:

```sh
mix test test/open_payments_snippets/payment_macros_test.exs
```

## Isolated consumer check

Build a production executable and run the CLI against a clean, committed SDK
snapshot in a temporary workspace:

```sh
elixir scripts/check_consumer.exs
# Use cached Hex dependencies without registry/network access:
elixir scripts/check_consumer.exs --offline
```

The default exports the sibling SDK's committed `HEAD` and prints its full commit
ID. Select another local checkout or an available commit explicitly with
`--sdk-path <directory>` and `--sdk-ref <revision>`. The check copies CLI source,
tests and the lockfile, builds dependencies from scratch, compiles a production
escript, runs `mix check`, then performs eight executable smoke tests and six
complete executable flows. Each subprocess runs outside the checkout with real
stdin and separate stdout/stderr capture. Environment wallet credentials are
cleared before testing; flow tests supply public keys and local simulated servers.
The temporary SDK, CLI copy and build output are removed afterward.

The smoke tests cover help/version, payment pointers, key loading/export, literal
environment-file templates, UTF-8 stdin, offline callback verification, error exits
and production archive contents. The executable flows cover
both low-level payment variants, the staged flow through confirmed outgoing
creation, and the macros with immediate grants, separate consent callbacks and
a real self-payment shell pipeline. They also exercise token rotation/revocation
and grant cancellation. Normal `mix test`
continues to run those scenarios through the testable CLI runner.

For an environment without Git, provide a source archive exported beforehand:

```sh
git -C ../open-payments-elixir archive --format=tar \
  --output=/tmp/open-payments-sdk.tar HEAD -- \
  mix.exs mix.lock README.md LICENSE CHANGELOG.md lib priv
elixir scripts/check_consumer.exs --sdk-archive /tmp/open-payments-sdk.tar --offline
```

Archive mode prints the archive's SHA256. Use a known committed revision when
exporting it to reproduce a particular SDK snapshot. Offline mode requires the
locked dependencies and Hex tooling to be cached already.

Verified with SDK commit `8d31b6f9ee7efab5b38601212b3ebc62841fed7c`:

| Runtime | Isolated result |
| --- | --- |
| Linux Elixir 1.17.3 / OTP 26 | 368 runner tests, 8 executable smoke tests and 6 executable flows |
| Linux Elixir 1.19.7 / OTP 28 | Same checks pass |
| Linux Elixir 1.20.5 / OTP 29 | Same checks pass |
| macOS Elixir 1.20.4 / OTP 29 | Same checks pass using an explicit Git export |

The Linux checks used cached images with networking disabled and source mounts
read-only. Fresh Elixir 1.20 builds emit two existing `message_signatures`
dependency deprecation warnings; CLI compilation and checks pass. Hosted CI and
live authenticated-provider verification remain pending.

## Continuous integration

[The CI workflow](.github/workflows/ci.yml) runs on pushes, pull requests and manual
dispatch. Its Ubuntu 24.04 matrix covers Elixir/OTP 1.17/26, 1.19/28 and 1.20/29.
Each job runs the isolated consumer check, including production executable build,
368 runner tests, eight executable smoke tests and six complete executable flows.

CI checks out the public SDK at
[`8d31b6f9ee7efab5b38601212b3ebc62841fed7c`](https://github.com/interledger/open-payments-elixir/commit/8d31b6f9ee7efab5b38601212b3ebc62841fed7c).
The workflow's `SDK_REVISION` selects that exact commit. Update it deliberately
when adopting a newer remotely available SDK revision, and verify the same local
consumer check with `--sdk-ref` before changing the pin. Ordinary development
continues to use the sibling SDK checkout.

Checkout/setup actions are pinned to commit hashes. The workflow uses read-only
repository permissions, avoids persisting checkout credentials and supplies no
wallet credentials. Tests use public fixtures and loopback servers.

The workflow passes actionlint, and its pinned SDK revision passes the local
offline container matrix. Hosted execution remains unverified until a run occurs.
