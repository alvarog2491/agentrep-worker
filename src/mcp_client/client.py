import os
import boto3
import httpx
from botocore.auth import SigV4Auth
from botocore.awsrequest import AWSRequest
from mcp.client.streamable_http import streamable_http_client
from strands.tools.mcp.mcp_client import MCPClient

REGION = os.getenv("AWS_REGION", "us-east-1")
SERVICE = "bedrock-agentcore"


class _SigV4Auth(httpx.Auth):
    """Signs httpx requests with AWS SigV4 using the runtime execution role credentials."""

    def __init__(self, service: str, region: str):
        self._service = service
        self._region = region

    def auth_flow(self, request: httpx.Request):
        credentials = boto3.Session().get_credentials().get_frozen_credentials()

        aws_request = AWSRequest(
            method=request.method.upper(),
            url=str(request.url),
            data=request.content,
            headers={
                k: v for k, v in request.headers.items()
                if k.lower() not in ("authorization", "x-amz-security-token", "x-amz-date", "x-amz-content-sha256")
            },
        )

        SigV4Auth(credentials, self._service, self._region).add_auth(aws_request)

        for key, value in aws_request.headers.items():
            request.headers[key] = value

        yield request


def get_mcp_client() -> MCPClient:
    """
    Returns an MCP Client authenticated via SigV4, using the runtime execution role.
    Requires env var: MCP_SERVER_URL
    """
    server_url = os.environ["MCP_SERVER_URL"]
    auth = _SigV4Auth(SERVICE, REGION)
    return MCPClient(lambda: streamable_http_client(
        server_url,
        http_client=httpx.AsyncClient(auth=auth),
    ))
