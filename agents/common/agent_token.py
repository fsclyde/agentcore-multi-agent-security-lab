"""The agent's own Cognito token (client credentials), used to call tools.

The client secret is read from Secrets Manager with the runtime's role, which
can read this one secret only. The token lasts 15 minutes and is cached.
"""

import base64
import json
import os
import time
import urllib.parse
import urllib.request

import boto3

_cache = {"token": None, "exp": 0.0}


def _client_secret() -> str:
    sm = boto3.client("secretsmanager", region_name=os.environ["AWS_REGION"])
    return sm.get_secret_value(SecretId=os.environ["CLIENT_SECRET_ID"])["SecretString"]


def get() -> str:
    if _cache["token"] and time.time() < _cache["exp"] - 60:
        return _cache["token"]

    basic = base64.b64encode(f"{os.environ['CLIENT_ID']}:{_client_secret()}".encode()).decode()
    req = urllib.request.Request(
        os.environ["TOKEN_ENDPOINT"],
        data=urllib.parse.urlencode({"grant_type": "client_credentials", "scope": os.environ["TOKEN_SCOPE"]}).encode(),
        headers={"Authorization": f"Basic {basic}", "Content-Type": "application/x-www-form-urlencoded"},
    )
    with urllib.request.urlopen(req, timeout=10) as resp:
        body = json.loads(resp.read())
    _cache.update(token=body["access_token"], exp=time.time() + body["expires_in"])
    return _cache["token"]
