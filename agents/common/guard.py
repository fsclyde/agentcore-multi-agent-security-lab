"""Bedrock Guardrails, applied explicitly at every hop.

check(text, source) returns (allowed, text). When the guardrail anonymises
(e-mails, tokens, passwords) the masked text is returned; when it blocks
(prompt attack, AWS keys, destructive request) allowed is False.

Each agent calls it on:
  - what it receives (from a person or from another agent): source="INPUT"
  - what it sends back:                                     source="OUTPUT"
"""

import os

import boto3

_client = boto3.client("bedrock-runtime", region_name=os.environ["AWS_REGION"])
_ID = os.environ["GUARDRAIL_ID"]
_VERSION = os.environ["GUARDRAIL_VERSION"]


def check(text: str, source: str = "INPUT") -> tuple[bool, str]:
    resp = _client.apply_guardrail(
        guardrailIdentifier=_ID,
        guardrailVersion=_VERSION,
        source=source,
        content=[{"text": {"text": text}}],
    )
    if resp["action"] != "GUARDRAIL_INTERVENED":
        return True, text

    masked = "".join(o.get("text", "") for o in resp.get("outputs", []))
    blocked = any(
        a.get("action") == "BLOCKED"
        for assessment in resp.get("assessments", [])
        for policy in assessment.values()
        if isinstance(policy, dict)
        for group in policy.values()
        if isinstance(group, list)
        for a in group
    )
    print(f"guardrail intervened source={source} blocked={blocked}")
    return (not blocked), masked
