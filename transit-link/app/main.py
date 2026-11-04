"""Application entry point: wires routers, start-up and the static web apps.

Linked to: db (init_db), seed (ensure_demo), every router, and the web/ folder.
Run:  uvicorn app.main:app --reload     then open http://localhost:8000
"""
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import APIRouter, FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles

from .config import settings
from .db import init_db
from .routers import auth, operator, taps, topups, wallet

WEB_DIR = Path(__file__).resolve().parent.parent / "web"


@asynccontextmanager
async def lifespan(_: FastAPI):
    init_db()
    if settings.auto_seed:
        from .seed import ensure_demo

        ensure_demo()
    yield


app = FastAPI(title="Transit Link MVP", version="0.1.0", lifespan=lifespan)

if settings.cors_origins:
    app.add_middleware(CORSMiddleware, allow_origins=settings.cors_origins, allow_methods=["*"], allow_headers=["*"])

api = APIRouter(prefix="/api")
for module in (auth, wallet, topups, taps, operator):
    api.include_router(module.router)


@api.get("/health", tags=["meta"])
def health():
    return {"status": "ok", "mpesa_mode": settings.mpesa_mode}


app.include_router(api)

# Must be last: serves /, /rider/, /validator/ and /operator/ from the web folder.
app.mount("/", StaticFiles(directory=WEB_DIR, html=True), name="web")
