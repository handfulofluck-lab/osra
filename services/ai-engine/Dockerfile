FROM python:3.11-slim
WORKDIR /app
COPY requirements.txt .
# Install CPU-only PyTorch first so linux/amd64 Fargate images stay lean without CUDA wheels.
RUN pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cpu torch==2.3.0 \
 && pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
