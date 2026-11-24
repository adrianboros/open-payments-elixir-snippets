#!/usr/bin/env python3
"""Opt-in live acceptance checks through the built CLI; no wallet defaults."""
import argparse
import hashlib
import json
import math
import os
from pathlib import Path
import re
import secrets
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone

REPO = Path(__file__).resolve().parent.parent
RECIPES = json.loads((REPO / "examples/live-scenarios.json").read_text())


class CheckFailed(Exception):
    pass


def require(condition, message="Acceptance check failed; inspect private state."):
    if not condition:
        raise CheckFailed(message)


def private_write(path, data):
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, "w") as output:
        output.write(json.dumps(data, indent=2) + "\n" if not isinstance(data, str) else data)


def read(path):
    return json.loads(path.read_text())


def public_amount(data):
    value, code, scale = data["value"], data["assetCode"], data["assetScale"]
    require(isinstance(value, str) and re.fullmatch(r"[0-9]+", value) is not None)
    require(int(value) <= 2**64 - 1 and code in ("EUR", "GBP") and type(scale) is int and scale == 2)
    return {"value": value, "assetCode": code, "assetScale": scale}


def public_result(data):
    """A positive allowlist: never copy URLs, IDs, run labels or raw metadata."""
    scenario = data["scenario"]
    require(scenario in RECIPES and data["status"] == "passed")
    sdk = data["sdk"]
    require(sdk["sdk"] == "open_payments_elixir" and sdk["sdkSource"] in ("hex", "local"))
    for key in ("sdkVersion", "cliVersion"):
        require(re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", sdk[key]) is not None)
    result = {"scenario": scenario, "status": "passed", "sdk": {
        key: sdk[key] for key in ("sdk", "sdkVersion", "sdkSource", "cliVersion")}}
    for key in ("metadataVerified", "incomingCompleted", "tokensRevoked", "grantsCancelled"):
        require(data[key] is True)
        result[key] = True
    if scenario == "hourly-stream":
        for key in ("budget", "contribution", "spent", "remaining"):
            result[key] = public_amount(data[key])
        require(data["sameToken"] is True and data["count"] == RECIPES[scenario]["count"])
        result.update(count=data["count"], sameToken=True, intervalDuration="PT1H")
        for key in ("elapsedSeconds", "minimumSpacingSeconds"):
            require(type(data[key]) in (int, float) and math.isfinite(data[key]) and data[key] >= 0)
            result[key] = round(data[key], 6)
    else:
        result["debit"] = public_amount(data["debit"])
        result["received"] = public_amount(data["received"])
    return result


class Runner:
    def __init__(self, directory, executable, env_files=()):
        self.directory = Path(directory).absolute()
        self.executable = str(Path(executable).absolute())
        self.env_files = list(map(str, map(Path.absolute, map(Path, env_files))))
        self.state = None

    def path(self, name):
        return self.directory / name

    def call(self, label, arguments, payload=None):
        # Exclusive attempt creation precedes every subprocess, including any POST.
        private_write(self.path(label + ".attempt.json"), {"started": True})
        if payload is not None:
            private_write(self.path(label + ".request.json"), payload)
        flags = [part for path in self.env_files for part in ("--env-file", path)]
        flags += ["--env-file", str(self.path("metadata.env")), "--json"]
        environment = dict(os.environ)
        for name in ("TEST_RUN_ID", "TEST_SCENARIO", "ACCESS_TOKEN"):
            environment.pop(name, None)
        with os.fdopen(os.open(self.path(label + ".stdout"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as output, \
             os.fdopen(os.open(self.path(label + ".stderr"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "w") as error:
            result = subprocess.run([self.executable] + arguments + flags,
                                    input=json.dumps(payload) if payload is not None else "",
                                    text=True, stdout=output, stderr=error, env=environment, cwd=REPO)
        require(result.returncode == 0, "CLI operation failed; inspect protected stdout/stderr. No request was retried.")
        return read(self.path(label + ".stdout"))

    def persist(self):
        with tempfile.NamedTemporaryFile(mode="w", dir=self.directory, delete=False) as output:
            json.dump(self.state, output, indent=2)
            temporary = output.name
        os.replace(temporary, self.path("state.json"))

    def amount(self, role, value):
        wallet = self.state["wallets"][role]
        return {"value": str(value), "assetCode": wallet["assetCode"], "assetScale": wallet["assetScale"]}

    def metadata(self, suffix):
        return {"description": "Open Payments via Elixir SDK - acceptance " + self.state["scenario"] + suffix,
                "testScenario": "acceptance-" + self.state["scenario"]}

    def next_step(self, result, session=None):
        if session:
            result = {"status": result["status"], "stage": "sender-grant",
                      "consent_url": read(session)["response"].get("interact", {}).get("redirect")}
        private_write(self.path("next-step-" + secrets.token_hex(4) + ".json"), result)
        return {"status": result["status"], "stage": result.get("stage"),
                "instruction": ("Read the private next-step file for consent; then resume with its callback file."
                                if result["status"] == "pending" else "Resume to execute the bounded acceptance test.")}

    def initialize(self, scenario):
        self.directory.parent.mkdir(parents=True, exist_ok=True)
        self.directory.mkdir(mode=0o700)  # A new directory is required for every run.
        self.state = {"scenario": scenario, "recipe": RECIPES[scenario], "envFiles": self.env_files,
                      "status": "initializing", "wallets": {}, "runId": secrets.token_hex(16)}
        private_write(self.path("metadata.env"), "TEST_RUN_ID=" + self.state["runId"] +
                      "\nTEST_SCENARIO=acceptance-" + scenario + "\n")
        self.persist()
        config = self.call("configuration", ["input", "render", str(REPO / "examples/live-test-wallets.json")])
        for role in ("client", "EUR", "GBP"):
            wallet = self.call("wallet-" + role, ["wallet", "get", config[role]])
            if role != "client":
                require(wallet["assetCode"] == role and wallet["assetScale"] == 2,
                        "Configured test wallets must match their currency and scale 2.")
            self.state["wallets"][role] = wallet
        self.state["finishUris"] = {"receiver": config["receiverFinishUri"], "sender": config["senderFinishUri"]}
        self.persist()
        recipe = self.state["recipe"]
        if scenario == "hourly-stream":
            return self.initialize_stream()
        request = {"sender": self.state["wallets"][recipe["sender"]]["id"],
                   "receiver": self.state["wallets"][recipe["receiver"]]["id"],
                   "receiveAmount": self.amount(recipe["receiver"], recipe["receiveValue"]),
                   "finishUri": config["receiverFinishUri"], "metadata": self.metadata(""),
                   "senderAuthorization": {"debitAmount": self.amount(recipe["sender"], recipe["maxDebitValue"]),
                                           "finishUri": config["senderFinishUri"]}}
        result = self.call("initialize", ["payment", "initialize", "-", "--output", str(self.path("payment.json"))], request)
        self.state["status"] = "initialized"
        self.persist()
        return self.next_step(result)

    def initialize_stream(self):
        recipe, wallets = self.state["recipe"], self.state["wallets"]
        # The low-level grant command discovers the signing client's auth server.
        require(all(wallets[role]["authServer"] == wallets["client"]["authServer"]
                    for role in (recipe["sender"], recipe["receiver"])),
                "This live stream recipe requires the resource wallets and client to share an auth server.")
        for role in ("receiver", "sender"):
            access = {"type": "incoming-payment" if role == "receiver" else "outgoing-payment",
                      "actions": ["create", "read", "complete"] if role == "receiver" else ["create", "read"],
                      "identifier": wallets[recipe[role]]["id"]}
            request = {"client": wallets["client"]["id"], "access_token": {"access": [access]}}
            if role == "sender":
                interval = "R/" + datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z") + "/PT1H"
                self.state["interval"] = interval
                access["limits"] = {"debitAmount": self.amount(recipe["sender"], recipe["budgetValue"]), "interval": interval}
                request["interact"] = {"start": ["redirect"], "finish": {"method": "redirect",
                    "uri": self.state["finishUris"]["sender"], "nonce": secrets.token_urlsafe(32)}}
            result = self.call(role + "-grant", ["grant", "request", "-", "--output", str(self.path(role + ".json"))], request)
            if role == "receiver":
                require(result["status"] == "approved", "Receiver grant needs manual reconciliation before creating the stream.")
                token = self.token("receiver", read(self.path("receiver.json")))
                self.state["incoming"] = self.call("incoming-create", ["incoming", "create", "-", "--access-token-file", token],
                    {"walletAddress": wallets[recipe["receiver"]]["id"], "metadata": self.metadata(" - open incoming")})
        self.state["status"] = "initialized"
        self.persist()
        return self.next_step(result, self.path("sender.json"))

    def token(self, label, session):
        path = self.path(label + "-token.txt")
        private_write(path, session["response"]["access_token"]["value"])
        return str(path)

    def resume(self, callback=None):
        require(not self.directory.is_symlink() and self.directory.stat().st_mode & 0o077 == 0,
                "Live state must be an owner-only directory.")
        lock = self.path(".lock")
        lock.mkdir(mode=0o700)
        try:
            self.state = read(self.path("state.json"))
            self.env_files = self.state["envFiles"]
            require(self.state["status"] == "initialized", "This run is not ready to resume; inspect its private state.")
            if self.state["scenario"] == "hourly-stream":
                sender = read(self.path("sender.json"))
                if not sender["response"].get("access_token"):
                    require(callback is not None and Path(callback).is_file(), "Supply the sender consent callback file.")
                self.state["status"] = "executing"  # Blocks restarts after a partial stream.
                self.persist()
                return self.stream(callback)
            return self.normal(callback)
        finally:
            lock.rmdir()

    def normal(self, callback):
        session_path = self.path("payment.json")
        session = read(session_path)
        arguments = ["payment", "finalize", str(session_path), "--yes"]
        if session["response"].get("interact") and not session.get("callback_verified"):
            require(callback is not None and Path(callback).is_file(), "Supply the consent callback file before resuming.")
            arguments += ["--callback-file", str(Path(callback).absolute())]
        stage = session["payment"]["stage"]
        result = self.call("finalize-" + stage, arguments)
        if result["stage"] != "outgoing-created":
            return self.next_step(result)
        self.state["status"] = "executing"
        self.persist()
        session = read(session_path)
        payment = session["payment"]
        private_write(self.path("receiver.json"), payment["receiver_grant"])
        sender_token = self.token("sender", session)
        receiver_token = self.token("receiver", payment["receiver_grant"])
        outgoing, incoming = self.delivery("payment", payment["outgoing_payment"]["id"], payment["incoming_payment"]["id"],
                                           sender_token, receiver_token, payment["incoming_request"]["incomingAmount"])
        require(outgoing["metadata"] == incoming["metadata"] == payment["incoming_request"]["metadata"])
        require(incoming["completed"] is True)
        self.cleanup({"sender": session_path, "receiver": self.path("receiver.json")})
        return self.finish({"debit": outgoing["debitAmount"], "received": incoming["receivedAmount"],
                            "sdk": incoming["metadata"]["openPaymentsSnippets"]})

    def delivery(self, label, outgoing_id, incoming_id, sender_token, receiver_token, expected):
        for attempt in range(6):
            outgoing = self.call(label + "-outgoing-read-" + str(attempt),
                                 ["outgoing", "get", outgoing_id, "--access-token-file", sender_token])
            incoming = self.call(label + "-incoming-read-" + str(attempt),
                                 ["incoming", "get", incoming_id, "--access-token-file", receiver_token])
            require(outgoing.get("failed") is not True, "Provider reported a failed outgoing payment.")
            if outgoing.get("failed") is False and outgoing["sentAmount"] == outgoing["debitAmount"] and incoming["receivedAmount"] == expected:
                return outgoing, incoming
            time.sleep(1)
        raise CheckFailed("Delivery not confirmed within bounded read checks; reconcile private state.")

    def stream(self, callback):
        recipe = self.state["recipe"]
        sender = read(self.path("sender.json"))
        if not sender["response"].get("access_token"):
            require(callback is not None and Path(callback).is_file(), "Supply the sender consent callback file.")
            self.call("sender-continue", ["grant", "continue", str(self.path("sender.json")),
                                         "--callback-file", str(Path(callback).absolute())])
            sender = read(self.path("sender.json"))
        limits = sender["response"]["access_token"]["access"][0]["limits"]
        require(limits["debitAmount"] == self.amount(recipe["sender"], recipe["budgetValue"]) and limits["interval"] == self.state["interval"])
        sender_token = self.token("sender", sender)
        receiver_token = self.token("receiver-stream", read(self.path("receiver.json")))
        fingerprint = hashlib.sha256(Path(sender_token).read_bytes()).digest()
        incoming = self.state["incoming"]
        starts = []
        for index in range(1, recipe["count"] + 1):
            if starts:
                time.sleep(max(0, recipe["minimumSpacingSeconds"] - (time.monotonic() - starts[-1])))
            starts.append(time.monotonic())
            require(hashlib.sha256(Path(sender_token).read_bytes()).digest() == fingerprint)
            label = "contribution-" + str(index)
            metadata = dict(self.metadata(" - contribution " + str(index)), contribution=index,
                            hourlyBudget=self.amount(recipe["sender"], recipe["budgetValue"]))
            result = self.call(label, ["outgoing", "create", "-", "--access-token-file", sender_token],
                {"walletAddress": self.state["wallets"][recipe["sender"]]["id"], "incomingPayment": incoming["id"],
                 "debitAmount": self.amount(recipe["sender"], recipe["contributionValue"]), "metadata": metadata})
            outgoing, receipt = self.delivery(label, result["id"], incoming["id"], sender_token, receiver_token,
                self.amount(recipe["receiver"], index * int(recipe["contributionValue"])))
            require(outgoing["debitAmount"] == self.amount(recipe["sender"], recipe["contributionValue"]))
            require(outgoing["metadata"]["openPaymentsSnippets"] == incoming["metadata"]["openPaymentsSnippets"])
            require(receipt["metadata"] == incoming["metadata"])
        spent = self.call("spent", ["outgoing", "grant-spent-amounts", self.state["wallets"][recipe["sender"]]["id"],
                                    "--access-token-file", sender_token])["spentDebitAmount"]
        expected = int(recipe["contributionValue"]) * recipe["count"]
        require(spent == self.amount(recipe["sender"], expected))
        completed = self.call("incoming-complete", ["incoming", "complete", incoming["id"], "--access-token-file", receiver_token])
        require(completed["completed"] is True and completed["receivedAmount"] == self.amount(recipe["receiver"], expected))
        self.cleanup({role: self.path(role + ".json") for role in ("sender", "receiver")})
        return self.finish({"budget": self.amount(recipe["sender"], recipe["budgetValue"]),
            "contribution": self.amount(recipe["sender"], recipe["contributionValue"]), "spent": spent,
            "remaining": self.amount(recipe["sender"], int(recipe["budgetValue"]) - expected),
            "count": recipe["count"], "sameToken": True, "elapsedSeconds": starts[-1] - starts[0],
            "minimumSpacingSeconds": min(b - a for a, b in zip(starts, starts[1:])),
            "sdk": incoming["metadata"]["openPaymentsSnippets"]})

    def cleanup(self, sessions):
        for role, path in sessions.items():
            for resource, operation, status in (("token", "revoke", "revoked"), ("grant", "cancel", "cancelled")):
                result = self.call(role + "-" + operation, [resource, operation, str(path)])
                require(result["status"] == status)

    def finish(self, facts):
        result = dict(facts, scenario=self.state["scenario"], status="passed", metadataVerified=True,
                      incomingCompleted=True, tokensRevoked=True, grantsCancelled=True)
        result = public_result(result)
        private_write(self.path("result.json"), result)
        self.state["status"] = "passed"
        self.persist()
        return result


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("init", "resume", "report"))
    parser.add_argument("--state-dir", required=True, help="New private directory under .live-tests/")
    parser.add_argument("--scenario", choices=tuple(RECIPES))
    parser.add_argument("--env-file", action="append", default=[])
    parser.add_argument("--callback-file")
    parser.add_argument("--executable", default=str(REPO / "open-payments"))
    args = parser.parse_args(argv)
    directory = Path(args.state_dir).absolute()
    require(directory.resolve().is_relative_to((REPO / ".live-tests").resolve()),
            "Store operational state under the ignored .live-tests directory.")
    runner = Runner(directory, args.executable, args.env_file)
    if args.action == "init":
        require(args.scenario is not None, "Select a scenario for initialization.")
        result = runner.initialize(args.scenario)
    elif args.action == "resume":
        result = runner.resume(args.callback_file)
    else:
        result = public_result(read(runner.path("result.json")))
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    try:
        main()
    except (CheckFailed, OSError, ValueError, KeyError, TypeError):
        print("Live check stopped. Inspect private state; no operation was automatically retried.", file=sys.stderr)
        sys.exit(1)
