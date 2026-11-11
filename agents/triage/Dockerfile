# Build from the agents/ folder: docker buildx build --platform linux/arm64 -f triage/Dockerfile .
FROM --platform=linux/arm64 python:3.12-slim

RUN useradd --uid 10001 --create-home agent
WORKDIR /app

COPY triage/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY common/ ./
COPY triage/app.py ./

USER 10001
EXPOSE 8080
CMD ["python", "app.py"]
