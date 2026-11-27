from contextlib import asynccontextmanager
from fastapi import FastAPI
from pydantic import BaseModel
from typing import Literal
from model import analyze_text
from own_model_service import router as own_model_router, warmup_own_models_from_env
from staging_qa import router as staging_qa_router


@asynccontextmanager
async def _lifespan(_app: FastAPI):
    warmup_own_models_from_env()
    yield


app = FastAPI(title="FamilyShield AI Engine", version="0.1.0", lifespan=_lifespan)
app.include_router(staging_qa_router)
app.include_router(own_model_router)

class AnalyzeRequest(BaseModel):
    text: str
    context: Literal["message", "search", "web", "chatbot", "bio"] = "message"
    child_age: int | None = None

class AnalyzeResponse(BaseModel):
    categories: dict[str, float]
    severity: Literal["info", "warning", "critical"]
    flagged: bool
    explanation: str
    model_version: str | None
    language: str
    cutoff: float
    path: Literal["own", "hybrid_second_look", "rules"]

@app.get("/health")
def health():
    return {"ok": True}

@app.post("/analyze", response_model=AnalyzeResponse)
def analyze(req: AnalyzeRequest):
    return analyze_text(req.text, req.context, req.child_age)
