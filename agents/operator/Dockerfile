# Build from the agents/ folder: docker buildx build --platform linux/arm64 -f operator/Dockerfile .
FROM --platform=linux/arm64 python:3.12-slim

RUN useradd --uid 10001 --create-home agent
WORKDIR /app

COPY operator/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY common/ ./
COPY operator/app.py ./

USER 10001
EXPOSE 9000
CMD ["python", "app.py"]
