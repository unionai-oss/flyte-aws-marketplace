"""Idle polling agent.

Every minute: idle = 0 if a Flyte execution is in an active phase OR traefik
logged a recent (non-health) request; else idle += 1. Publishes IdleMinutes
to CloudWatch. A CloudWatch alarm on the metric drives the stop lambda. So both
running workloads and active UI/CLI use keep the box awake.

Auth is enforced at the ALB (Cognito jwt-validation / authenticate-cognito), so
every non-health request that reaches the box's traefik ingress is already
authenticated — a recent access-log line therefore means someone is
authentically using the console/CLI.
"""
from __future__ import annotations
import asyncio, json, logging, os, subprocess, time
from pathlib import Path
import boto3, flyte
from flyte.models import ActionPhase
from flyte.remote import Run

_ENDPOINT = os.environ.get("FLYTE_ENDPOINT", "localhost:30080")
_POLL_INTERVAL_SECONDS = int(os.environ.get("POLL_INTERVAL_SECONDS", "60"))
_METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "FlyteDevbox")
_INSTANCE_ID = os.environ["INSTANCE_ID"]
_REGION = os.environ["AWS_REGION"]
# Traefik (the devbox ingress) emits one JSON access-log line per request on the
# pod's stdout (enabled via the baked traefik-accesslog HelmChartConfig). The
# idle-agent reads them through the k3s API. Health probes carry these paths and
# are excluded, so a remaining recent line == authenticated console/CLI use.
_DEVBOX_CONTAINER = os.environ.get("DEVBOX_CONTAINER", "flyte-devbox")
_HEALTH_PATHS = ("/healthz", "/readyz")
_UI_ACTIVITY_LOOKBACK_SECONDS = 300
_STATE_FILE = Path("/var/lib/flyte-idle-agent/state")
_ACTIVE_PHASES: tuple[ActionPhase, ...] = (
    ActionPhase.QUEUED,
    ActionPhase.WAITING_FOR_RESOURCES,
    ActionPhase.INITIALIZING,
    ActionPhase.RUNNING,
)

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("flyte-idle-agent")

def _read_state() -> int:
    try: return int(_STATE_FILE.read_text().strip())
    except (FileNotFoundError, ValueError): return 0

def _write_state(v: int) -> None:
    _STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    _STATE_FILE.write_text(str(v))

async def _any_active_runs() -> bool:
    async for _ in Run.listall.aio(in_phase=_ACTIVE_PHASES, limit=1):
        return True
    return False

def _recent_ui_activity() -> bool:
    """True if traefik logged a non-health request within the lookback window.

    Keeps the box awake while someone browses the console or uses the CLI. Auth
    is enforced at the ALB, so any request reaching traefik is authenticated;
    only the health/readiness probes are excluded. Reads the traefik pod's JSON
    access log via `docker exec <container> kubectl logs --since=<lookback>`, so
    the time window is bounded by kubectl. Any error (eval mode / no cluster /
    kubectl not ready) -> False (no UI activity).
    """
    try:
        out = subprocess.run(
            ["docker", "exec", _DEVBOX_CONTAINER, "kubectl", "logs",
             "-n", "kube-system", "-l", "app.kubernetes.io/name=traefik",
             "--since=%ds" % _UI_ACTIVITY_LOOKBACK_SECONDS, "--tail=2000"],
            capture_output=True, text=True, timeout=20,
        ).stdout
    except (subprocess.SubprocessError, OSError):
        return False
    for line in out.splitlines():
        line = line.strip()
        if not line.startswith("{") or '"RequestPath"' not in line:
            continue
        try:
            path = json.loads(line).get("RequestPath", "")
        except ValueError:
            continue
        if path and not any(path.startswith(h) for h in _HEALTH_PATHS):
            return True
    return False

def _publish(cw, idle_minutes: int) -> None:
    cw.put_metric_data(
        Namespace=_METRIC_NAMESPACE,
        MetricData=[{
            "MetricName": "IdleMinutes",
            "Dimensions": [{"Name": "InstanceId", "Value": _INSTANCE_ID}],
            "Value": float(idle_minutes),
            "Unit": "Count",
        }],
    )

async def _poll_once(cw, idle_minutes: int) -> int:
    try: active = await _any_active_runs()
    except Exception:
        log.exception("query failed; idle unchanged")
        return idle_minutes
    # A running workload OR recent console/CLI activity resets the idle counter,
    # so actively using the UI keeps the box awake even with nothing executing.
    ui_active = False
    if not active:
        ui_active = _recent_ui_activity()
        active = ui_active
    new_value = 0 if active else idle_minutes + max(1, _POLL_INTERVAL_SECONDS // 60)
    try: _publish(cw, new_value)
    except Exception: log.exception("publish failed")
    _write_state(new_value)
    log.info("idle_minutes=%d active=%s ui_active=%s", new_value, active, ui_active)
    return new_value

async def _main() -> None:
    flyte.init(endpoint=_ENDPOINT, insecure=True)
    cw = boto3.client("cloudwatch", region_name=_REGION)
    idle_minutes = _read_state()
    log.info("starting endpoint=%s poll=%ss state=%d", _ENDPOINT, _POLL_INTERVAL_SECONDS, idle_minutes)
    while True:
        t0 = time.monotonic()
        idle_minutes = await _poll_once(cw, idle_minutes)
        await asyncio.sleep(max(0.0, _POLL_INTERVAL_SECONDS - (time.monotonic() - t0)))

if __name__ == "__main__":
    asyncio.run(_main())
