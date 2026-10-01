"""Exercise the locked HTTP parser below the dashboard response-size cap."""

import io
from http.client import HTTPResponse as WireResponse
from unittest.mock import MagicMock

import pytest
from urllib3.exceptions import ProtocolError
from urllib3.response import HTTPResponse


def _chunked_response(chunk_line):
    wire = (
        b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
        + chunk_line
        + b"\r\na\r\n0\r\n\r\n"
    )
    sock = MagicMock()
    sock.makefile.return_value = io.BytesIO(wire)
    response = WireResponse(sock)
    response.begin()
    return HTTPResponse(body=response, headers=dict(response.getheaders()), preload_content=False)


def test_chunked_stream_accepts_normal_extensions():
    with _chunked_response(b"1;extension=value") as response:
        assert b"".join(response.stream(65536)) == b"a"


def test_chunk_size_line_is_bounded_before_reading_the_body():
    # A one-byte body passes our application cap, but its framing must also be bounded.
    # urllib3 2.7.0 reads this whole line and accepts it; 2.8.0 rejects it.
    with _chunked_response(b"1;" + b"x" * 65536) as response:
        with pytest.raises(ProtocolError, match="chunk size line exceeded"):
            list(response.stream(65536))
