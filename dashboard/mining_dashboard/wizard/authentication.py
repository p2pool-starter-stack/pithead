from aiohttp import web


def token_middleware(authenticated):
    @web.middleware
    async def require_token(request, handler):
        if (
            request.method not in {"GET", "HEAD", "OPTIONS"}
            and request.path != "/auth"
            and not authenticated(request)
        ):
            raise web.HTTPForbidden(text="Console authorization required.")
        return await handler(request)

    return require_token
