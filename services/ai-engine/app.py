from fastapi import FastAPI
from pydantic import BaseModel
from typing import Literal
from model import analyze_text

app = FastAPI(title="FamilyShield AI Engine", version="0.1.0")

class AnalyzeRequest(BaseModel):
    text: str
    context: Literal["message", "search", "web", "chatbot", "bio"] = "message"
    child_age: int | None = None

class AnalyzeResponse(BaseModel):
    categories: dict[str, float]
    severity: Literal["info", "warning", "critical"]
    flagged: bool
    explanation: str

@app.get("/health")
def health():
    return {"ok": True}

@app.post("/analyze", response_model=AnalyzeResponse)
def analyze(req: AnalyzeRequest):
    return analyze_text(req.text, req.context, req.child_age)
