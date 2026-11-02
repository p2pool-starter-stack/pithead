import os

from aiohttp import web


async def legacy(_request):
    return web.Response(text="legacy dashboard")


async def missing_readiness(_request):
    raise web.HTTPNotFound()


app = web.Application()
app.router.add_route("*", "/api/auth/ready", missing_readiness)
app.router.add_route("*", "/{path:.*}", legacy)
web.run_app(app, host=os.environ["BACKEND_HOST"], port=int(os.environ["BACKEND_PORT"]), print=None)
