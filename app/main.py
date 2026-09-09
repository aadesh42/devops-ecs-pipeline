import logging
import os
import sys

from fastapi import FastAPI

logging.basicConfig(
    stream=sys.stdout,
    level=logging.INFO,
    format='{"level":"%(levelname)s","logger":"%(name)s","msg":"%(message)s"}',
)
log = logging.getLogger("app")

app = FastAPI(title="devops-demo")

APP_VERSION = os.getenv("APP_VERSION", "dev")
ENVIRONMENT = os.getenv("ENVIRONMENT", "local")


@app.get("/")
def root():
    log.info("root endpoint hit")
    return {
        "service": "devops-demo",
        "version": APP_VERSION,
        "env": ENVIRONMENT,
        "deployed_by": "github-actions",
    }


@app.get("/health")
def health():
    return {"status": "ok"}
