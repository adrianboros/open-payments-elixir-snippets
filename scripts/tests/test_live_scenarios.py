"""Offline orchestration and export-boundary tests. No provider is contacted."""
import importlib.util
import json
import re
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("live_scenarios", Path(__file__).parents[1] / "live_scenarios.py")
live = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(live)

SDK = {"sdk": "open_payments_elixir", "sdkVersion": "1.0.0", "sdkSource": "hex", "cliVersion": "0.1.0",
       "runId": "PRIVATE-RUN", "wallet": "https://private.example/sentinel"}
METADATA = {"openPaymentsSnippets": SDK, "private": "PRIVATE-METADATA"}


def amount(value, code="GBP"):
    return {"value": str(value), "assetCode": code, "assetScale": 2}


def session(role, access=None):
    return {"response": {"access_token": {"value": "PRIVATE-TOKEN-" + role, "access": access or []}}}


class Clock:
    def __init__(self):
        self.now = 0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class FakeRunner(live.Runner):
    """A deterministic provider contract for exercising the runner's workflows."""
    def __init__(self, root, scenario):
        super().__init__(root, "/not-executed")
        self.directory.mkdir(mode=0o700)
        self.calls = []
        self.state = {"scenario": scenario, "recipe": live.RECIPES[scenario], "status": "initialized", "envFiles": [],
                      "interval": "R/2026-11-24T00:00:00Z/PT1H", "wallets": {
                          code: {"id": "https://private.example/" + code, "assetCode": code, "assetScale": 2}
                          for code in ("EUR", "GBP")}}
        self.incoming = {"id": "https://private.example/incoming-payments/PRIVATE-ID", "metadata": METADATA}
        self.state["incoming"] = self.incoming
        self.clock = Clock()
        self.persist()

    def call(self, label, arguments, payload=None):
        self.calls.append((label, arguments, payload))
        if arguments[:2] == ["payment", "finalize"]:
            return {"stage": "outgoing-created", "status": "created"}
        if arguments[:2] == ["outgoing", "create"]:
            self.clock.sleep(0.2)
            return {"id": "https://private.example/outgoing-payments/PRIVATE-ID-" + label}
        if arguments[:2] == ["outgoing", "grant-spent-amounts"]:
            return {"spentDebitAmount": amount(8)}
        if arguments[:2] == ["incoming", "complete"]:
            return {"completed": True, "receivedAmount": amount(8)}
        if arguments[:2] == ["token", "revoke"]:
            return {"status": "revoked"}
        if arguments[:2] == ["grant", "cancel"]:
            return {"status": "cancelled"}
        raise AssertionError("Unexpected operation in offline provider")

    def delivery(self, label, outgoing_id, incoming_id, sender_token, receiver_token, expected):
        outgoing = {"failed": False, "metadata": METADATA, "debitAmount": amount(1)}
        incoming = {"completed": True, "metadata": METADATA, "receivedAmount": expected}
        if label == "payment":
            outgoing["debitAmount"] = amount(9089, "EUR")
        return outgoing, incoming


class LiveScenariosTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.addCleanup(self.temp.cleanup)

    def public_facts(self):
        return {"scenario": "hourly-stream", "status": "passed", "sdk": SDK, "metadataVerified": True,
                "incomingCompleted": True, "tokensRevoked": True, "grantsCancelled": True,
                "budget": amount(1000), "contribution": amount(1), "spent": amount(8), "remaining": amount(992),
                "count": 8, "sameToken": True, "elapsedSeconds": 46.683991, "minimumSpacingSeconds": 6.576434,
                "interval": "R/PRIVATE-START/PT1H", "payments": [{"id": "PRIVATE-ID"}],
                "rawResponse": {"access_token": "PRIVATE-TOKEN"}, "wallet": "https://private.example/wallet"}

    def test_public_export_keeps_documented_numbers_and_omits_unknown_private_fields(self):
        result = live.public_result(self.public_facts())
        encoded = json.dumps(result)
        for sentinel in ("PRIVATE", "https://", "wallet", "runId", "access_token", "rawResponse"):
            self.assertNotIn(sentinel, encoded)
        self.assertNotIn("payments", result)
        self.assertEqual(result["budget"], amount(1000))
        self.assertEqual(result["remaining"], amount(992))
        self.assertEqual(result["count"], 8)
        self.assertEqual(result["intervalDuration"], "PT1H")

    def test_export_rejects_private_values_smuggled_into_whitelisted_fields(self):
        for field, value in (("scenario", "PRIVATE-WALLET"), ("minimumSpacingSeconds", float("inf"))):
            data = self.public_facts()
            data[field] = value
            with self.assertRaises(live.CheckFailed):
                live.public_result(data)
        for value in ("https://private.example/version", "1.0.0/PRIVATE", "1.0.0-PRIVATE-WALLET", "PRIVATE"):
            data = self.public_facts()
            data["sdk"] = dict(SDK, sdkVersion=value)
            with self.assertRaises(live.CheckFailed):
                live.public_result(data)
        for field, value in (("value", "PRIVATE"), ("assetCode", "PRIVATE"), ("assetScale", True)):
            data = self.public_facts()
            data["budget"][field] = value
            with self.assertRaises(live.CheckFailed):
                live.public_result(data)

    def test_unknown_amount_extensions_and_sdk_extensions_never_escape(self):
        data = self.public_facts()
        data["budget"]["walletAddress"] = "PRIVATE"
        self.assertEqual(live.public_result(data)["budget"], amount(1000))
        self.assertEqual(set(live.public_result(data)["sdk"]), {"sdk", "sdkVersion", "sdkSource", "cliVersion"})

    def test_live_attempt_is_private_durable_and_never_replayed_after_failure(self):
        runner = live.Runner(self.root, "/not-executed")
        live.private_write(self.root / "metadata.env", "")
        def fail(command, **options):
            self.assertTrue((self.root / "payment.attempt.json").exists())
            options["stderr"].write("PRIVATE-TOKEN https://private.example/wallet")
            return subprocess.CompletedProcess(command, 1)
        with patch.object(live.subprocess, "run", side_effect=fail) as process:
            with self.assertRaises(live.CheckFailed):
                runner.call("payment", ["outgoing", "create", "-"], {"walletAddress": "PRIVATE"})
            with self.assertRaises(FileExistsError):
                runner.call("payment", ["outgoing", "create", "-"], {"walletAddress": "PRIVATE"})
            self.assertEqual(process.call_count, 1)
        for path in self.root.iterdir():
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_cli_failure_console_does_not_print_wallets_tokens_or_tracebacks(self):
        result = subprocess.run([sys.executable, live.__file__, "init", "--scenario", "hourly-stream",
                                 "--state-dir", str(self.root / "outside-ignored-root")], capture_output=True, text=True)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertNotIn(str(self.root), result.stderr)
        self.assertNotIn("Traceback", result.stderr)

    def test_hourly_stream_uses_one_budget_and_token_for_eight_spaced_contributions(self):
        runner = FakeRunner(self.root / "hourly", "hourly-stream")
        access = [{"limits": {"debitAmount": amount(1000), "interval": runner.state["interval"]}}]
        live.private_write(runner.path("sender.json"), session("sender", access))
        live.private_write(runner.path("receiver.json"), session("receiver"))
        with patch.object(live.time, "monotonic", runner.clock.monotonic), patch.object(live.time, "sleep", runner.clock.sleep):
            result = runner.resume()
        outgoing = [call for call in runner.calls if call[1][:2] == ["outgoing", "create"]]
        self.assertEqual(len(outgoing), 8)
        tokens = {call[1][call[1].index("--access-token-file") + 1] for call in outgoing}
        self.assertEqual(len(tokens), 1)
        self.assertTrue(all(call[2]["debitAmount"] == amount(1) for call in outgoing))
        self.assertEqual(result["spent"], amount(8))
        self.assertEqual(result["remaining"], amount(992))
        self.assertGreaterEqual(result["minimumSpacingSeconds"], 3.599999)
        self.assertEqual([call[0] for call in runner.calls[-4:]], ["sender-revoke", "sender-cancel", "receiver-revoke", "receiver-cancel"])
        self.assertNotIn("PRIVATE", json.dumps(result))
        with self.assertRaises(live.CheckFailed):
            runner.resume()

    def test_missing_callback_preserves_a_resumable_stream_before_any_payment(self):
        runner = FakeRunner(self.root / "callback", "hourly-stream")
        live.private_write(runner.path("sender.json"), {"response": {"interact": {"redirect": "PRIVATE"}}})
        with self.assertRaises(live.CheckFailed):
            runner.resume()
        self.assertEqual(live.read(runner.path("state.json"))["status"], "initialized")
        self.assertEqual(runner.calls, [])

    def test_narrowed_budget_is_rejected_before_any_outgoing_payment(self):
        runner = FakeRunner(self.root / "narrow", "hourly-stream")
        live.private_write(runner.path("sender.json"), session("sender", [{"limits": {
            "debitAmount": amount(1), "interval": runner.state["interval"]}}]))
        with self.assertRaises(live.CheckFailed):
            runner.resume()
        self.assertEqual(runner.calls, [])

    def test_initialization_binds_all_normal_recipes_to_runtime_wallet_roles(self):
        config = {"client": "https://private.example/client", "EUR": "https://private.example/eur",
                  "GBP": "https://private.example/gbp", "receiverFinishUri": "https://private.example/receiver-callback",
                  "senderFinishUri": "https://private.example/sender-callback"}
        def wallet(code, identifier):
            return {"id": identifier, "assetCode": code, "assetScale": 2, "authServer": "https://private.example/auth"}
        for scenario, recipe in live.RECIPES.items():
            if scenario == "hourly-stream":
                continue
            with self.subTest(scenario=scenario):
                runner = live.Runner(self.root / scenario, "/not-executed")
                def call(label, arguments, payload=None):
                    if label == "configuration":
                        return config
                    if label.startswith("wallet-"):
                        role = label[len("wallet-"):]
                        return wallet("EUR" if role == "client" else role, config[role])
                    self.assertEqual(payload["sender"], config[recipe["sender"]])
                    self.assertEqual(payload["receiver"], config[recipe["receiver"]])
                    self.assertEqual(payload["receiveAmount"], amount(recipe["receiveValue"], recipe["receiver"]))
                    self.assertEqual(payload["senderAuthorization"]["debitAmount"], amount(10000, recipe["sender"]))
                    return {"status": "pending", "stage": "sender-grant", "consent_url": "https://private.example/PRIVATE"}
                with patch.object(runner, "call", side_effect=call):
                    result = runner.initialize(scenario)
                self.assertNotIn("private.example", json.dumps(result))
                self.assertEqual(runner.state["status"], "initialized")

    def test_initialization_requests_one_hourly_budget_and_keeps_consent_private(self):
        runner = live.Runner(self.root / "initialize-hourly", "/not-executed")
        calls = []
        config = {"client": "https://private.example/client", "EUR": "https://private.example/eur",
                  "GBP": "https://private.example/gbp", "receiverFinishUri": "https://private.example/receiver-callback",
                  "senderFinishUri": "https://private.example/sender-callback"}
        def call(label, arguments, payload=None):
            calls.append((label, arguments, payload))
            if label == "configuration":
                return config
            if label.startswith("wallet-"):
                role = label[len("wallet-"):]
                return {"id": config[role], "assetCode": "GBP" if role == "GBP" else "EUR", "assetScale": 2,
                        "authServer": "https://private.example/auth"}
            if label == "receiver-grant":
                live.private_write(runner.path("receiver.json"), session("receiver"))
                return {"status": "approved"}
            if label == "incoming-create":
                self.assertNotIn("incomingAmount", payload)
                return {"id": "https://private.example/incoming-payments/PRIVATE", "metadata": METADATA}
            if label == "sender-grant":
                access = payload["access_token"]["access"]
                self.assertEqual(len(access), 1)
                self.assertEqual(access[0]["limits"]["debitAmount"], amount(1000))
                self.assertTrue(access[0]["limits"]["interval"].endswith("/PT1H"))
                live.private_write(runner.path("sender.json"), {"response": {"interact": {
                    "redirect": "https://private.example/PRIVATE-CONSENT"}}})
                return {"status": "pending"}
            raise AssertionError("Unexpected initialization operation")
        with patch.object(runner, "call", side_effect=call):
            result = runner.initialize("hourly-stream")
        self.assertEqual(sum(label == "sender-grant" for label, _, _ in calls), 1)
        self.assertFalse(any(args[:2] == ["outgoing", "create"] for _, args, _ in calls))
        self.assertNotIn("PRIVATE", json.dumps(result))
        self.assertNotIn("private.example", json.dumps(result))

    def test_concurrent_resume_is_rejected_before_any_provider_operation(self):
        runner = FakeRunner(self.root / "locked", "hourly-stream")
        runner.path(".lock").mkdir(mode=0o700)
        with self.assertRaises(FileExistsError):
            runner.resume()
        self.assertEqual(runner.calls, [])

    def test_saved_baseline_has_no_identifiers_and_its_amounts_reconcile(self):
        report = json.loads((Path(live.REPO) / "test-results/2026-11-24.json").read_text())
        def inspect(node):
            if isinstance(node, dict):
                self.assertFalse(set(node) & {"id", "walletAddress", "runId", "key_id", "nonce", "access_token", "callback", "rawResponse"})
                for value in node.values():
                    inspect(value)
            elif isinstance(node, list):
                for value in node:
                    inspect(value)
            elif isinstance(node, str):
                self.assertNotIn("://", node)
                self.assertIsNone(re.search(r"[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}", node, re.I))
        inspect(report)
        observed = report["live"]
        totals = {"EUR": 0, "GBP": 0}
        for result in observed["normalScenarios"]:
            live.public_result(result)
            totals[result["debit"]["assetCode"]] += int(result["debit"]["value"])
        hourly = live.public_result(observed["hourlyStream"])
        self.assertEqual(int(hourly["budget"]["value"]), int(hourly["spent"]["value"]) + int(hourly["remaining"]["value"]))
        ancillary = observed["earlierDirectPaymentCheck"]
        totals["GBP"] += int(hourly["spent"]["value"]) + int(ancillary["spent"]["value"])
        self.assertEqual(totals, {a["assetCode"]: int(a["value"]) for a in observed["totalDebits"]})
        self.assertEqual(observed["settledOutgoingPayments"], len(observed["normalScenarios"]) + hourly["count"] + ancillary["count"])

    def test_normal_payment_checks_delivery_metadata_and_cleans_up(self):
        runner = FakeRunner(self.root / "normal", "eur-to-gbp")
        outgoing = "https://private.example/outgoing-payments/PRIVATE-ID"
        incoming_request = {"incomingAmount": amount(7569), "metadata": METADATA}
        saved = dict(session("sender"), payment={"stage": "quote-ready", "outgoing_payment": {"id": outgoing},
            "incoming_payment": runner.incoming, "incoming_request": incoming_request, "receiver_grant": session("receiver")})
        live.private_write(runner.path("payment.json"), saved)
        result = runner.resume()
        self.assertEqual(result["debit"], amount(9089, "EUR"))
        self.assertEqual(result["received"], amount(7569))
        self.assertTrue(result["metadataVerified"])
        self.assertNotIn("PRIVATE", json.dumps(result))


if __name__ == "__main__":
    unittest.main()
