"""Operator agent: applies one reviewed repair, as an A2A worker.

Only an sre-admin's token reaches this runtime (AgentCore checks the
cognito:groups claim). Its tool calls are signed with the operator's own IAM
role and carry the person's token, and the Cedar policy at the gateway only
lets it change the image of demo-web in the demo namespace, for an sre-admin.
"""

import asyncio
import os

import uvicorn
from mcp.client.streamable_http import streamablehttp_client
from strands import Agent
from strands.models import BedrockModel
from strands.tools.mcp import MCPClient

import gateway_proxy
import guard
from a2a import server

SYSTEM = """You are the operator agent. You apply exactly one change that has been
approved by a second person. Call update_deployment_image once, with the
namespace, name, container, image and change_id from the request. Never change
anything else and never retry with different values.
Report what you changed in three lines or fewer. If the call is denied,
report the denial and stop."""

model = BedrockModel(
    model_id=os.environ["MODEL_ID"],
    region_name=os.environ["AWS_REGION"],
    guardrail_id=os.environ["GUARDRAIL_ID"],
    guardrail_version=os.environ["GUARDRAIL_VERSION"],
    guardrail_trace="enabled",
    max_tokens=1000,  # one short change, nothing more
)


def repair(task: str, bearer: str) -> str:
    ok, task = guard.check(task, "INPUT")
    if not ok:
        return task

    tools = MCPClient(lambda: streamablehttp_client("http://127.0.0.1:8100/mcp"))
    with gateway_proxy.acting_for(bearer), tools:
        agent = Agent(model=model, system_prompt=SYSTEM, tools=tools.list_tools_sync())
        answer = str(agent(task))

    ok, answer = guard.check(answer, "OUTPUT")
    return answer


app = server(
    name="operator",
    description="Applies one reviewed repair to the demo Deployment.",
    skills=[{"id": "repair", "name": "Apply a reviewed fix",
             "description": "Change the container image of demo-web in the demo namespace.",
             "tags": ["sre", "kubernetes", "write"]}],
    handle=repair,
)

async def main():
    await asyncio.gather(
        uvicorn.Server(uvicorn.Config(gateway_proxy.app, host="127.0.0.1", port=8100, log_level="warning")).serve(),
        uvicorn.Server(uvicorn.Config(app, host="0.0.0.0", port=9000)).serve(),
    )


if __name__ == "__main__":
    asyncio.run(main())
