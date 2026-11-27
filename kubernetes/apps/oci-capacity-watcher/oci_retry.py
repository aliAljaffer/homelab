#!/usr/bin/env python3
"""Idempotent OCI A1.Flex capacity watcher for a Kubernetes CronJob."""
from __future__ import annotations

import json
import logging
import os
import smtplib
import ssl
import sys
import time
import urllib.request
from datetime import timezone
from email.message import EmailMessage
from email.utils import formatdate
from pathlib import Path

import oci

BASE = Path(__file__).resolve().parent
CONFIG_ENV = Path(os.environ.get("OCI_WATCHER_CONFIG_ENV", BASE / "config.env"))
TAG_KEY = "oci-capacity-watcher"

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
    stream=sys.stdout,
)
logger = logging.getLogger("oci-capacity-watcher")


def load_env(path: Path) -> None:
    if not path.exists():
        return
    for raw in path.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
            value = value[1:-1]
        os.environ.setdefault(key.strip(), value)


load_env(CONFIG_ENV)


def env(name: str, default: str | None = None, required: bool = False) -> str:
    value = os.environ.get(name, default)
    if required and (value is None or not str(value).strip()):
        raise SystemExit(f"missing {name}")
    return str(value) if value is not None else ""


def truthy(name: str, default: str = "true") -> bool:
    return env(name, default).strip().lower() in ("1", "true", "yes", "on")


def oci_config() -> dict | None:
    path = Path(env("OCI_CONFIG_FILE", "~/.oci/config")).expanduser()
    if not path.exists():
        logger.error("OCI config not found at %s", path)
        return None
    try:
        cfg = oci.config.from_file(str(path), env("OCI_PROFILE", "DEFAULT"))
    except Exception as exc:
        logger.error("OCI config could not be loaded: %s", exc)
        return None
    region = env("OCI_REGION")
    if region:
        cfg["region"] = region
    return cfg


def pick_availability_domain(identity, cfg: dict) -> str:
    wanted = env("OCI_AD", "AD-1")
    domains = identity.list_availability_domains(cfg["tenancy"]).data
    if not domains:
        raise RuntimeError("no availability domains returned")
    for domain in domains:
        if domain.name == wanted or domain.name.endswith(wanted):
            return domain.name
    logger.warning("AD %r not found; using %s", wanted, domains[0].name)
    return domains[0].name


def pick_network(vn, compartment_id: str) -> str:
    vcn_name = env("OCI_VCN_NAME", "my-vcn", required=True)
    subnet_name = env("OCI_SUBNET_NAME", "pub-subnet", required=True)
    vcns = vn.list_vcns(compartment_id, lifecycle_state="AVAILABLE").data
    vcn = next((v for v in vcns if v.display_name == vcn_name), None)
    if vcn is None:
        raise RuntimeError(f"VCN {vcn_name!r} not found in compartment")
    subnets = vn.list_subnets(
        compartment_id, vcn_id=vcn.id, lifecycle_state="AVAILABLE"
    ).data
    subnet = next((s for s in subnets if s.display_name == subnet_name), None)
    if subnet is None:
        raise RuntimeError(f"subnet {subnet_name!r} not found in VCN {vcn_name!r}")
    return subnet.id


def pick_image(compute, compartment_id: str) -> str:
    configured = env("OCI_IMAGE_ID")
    if configured:
        return configured

    kwargs = {
        "compartment_id": compartment_id,
        "operating_system": env("OCI_OS", "Canonical Ubuntu"),
        "shape": "VM.Standard.A1.Flex",
        "sort_by": "TIMECREATED",
        "sort_order": "DESC",
    }
    os_version = env("OCI_OS_VERSION", "24.04")
    if os_version:
        kwargs["operating_system_version"] = os_version
    images = compute.list_images(**kwargs).data

    if not images and os_version:
        kwargs.pop("operating_system_version", None)
        images = compute.list_images(**kwargs).data
    if not images:
        raise RuntimeError("no compatible A1 image found; set OCI_IMAGE_ID")

    arm = [i for i in images if "aarch64" in (i.display_name or "").lower()]
    chosen = (arm or images)[0]
    logger.info("using image: %s (%s)", chosen.display_name, chosen.id)
    return chosen.id


def wait_for_public_ip(
    compute, vn, compartment_id: str, instance_id: str, timeout: int
) -> str | None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        try:
            attachments = compute.list_vnic_attachments(
                compartment_id, instance_id=instance_id
            ).data
            for attachment in attachments:
                if attachment.lifecycle_state != "ATTACHED":
                    continue
                vnic = vn.get_vnic(attachment.vnic_id).data
                if vnic.public_ip:
                    return vnic.public_ip
        except oci.exceptions.ServiceError as exc:
            logger.info("waiting for VNIC/public IP: %s", exc.message)
        time.sleep(5)
    return None


def send_mail(subject: str, body: str) -> bool:
    if not truthy("NOTIFY_ENABLED", "true"):
        return True

    host = env("SMTP_HOST", "smtp-relay.mail.svc.cluster.local")
    port = int(env("SMTP_PORT", "587"))
    to_addr = env("NOTIFY_TO", required=True)
    from_addr = env("NOTIFY_FROM", "homelab@alialjaffer.com")

    message = EmailMessage()
    message["From"] = from_addr
    message["To"] = to_addr
    message["Subject"] = subject
    message["Date"] = formatdate(localtime=True)
    message.set_content(body)

    try:
        with smtplib.SMTP(host, port, timeout=30) as smtp:
            smtp.send_message(message)
    except (OSError, smtplib.SMTPException) as exc:
        logger.error("mail delivery failed via %s:%s: %s", host, port, exc)
        return False
    logger.info("alert email sent to %s", to_addr)
    return True


def notify(instance, public_ip: str | None) -> bool:
    ip = public_ip or "pending"
    ssh_user = env("OCI_SSH_USER", "ubuntu")
    shape_config = getattr(instance, "shape_config", None)
    ocpus = getattr(shape_config, "ocpus", env("OCI_OCPUS", "2"))
    memory = getattr(shape_config, "memory_in_gbs", env("OCI_MEMORY_GBS", "12"))
    region = env("OCI_REGION", "me-riyadh-1")
    created = instance.time_created
    if created is not None:
        created = created.astimezone(timezone.utc).isoformat()

    body = (
        "Your Oracle Always Free A1.Flex instance was created.\n"
        "\n"
        f"Name:              {instance.display_name}\n"
        f"Shape:             {instance.shape} ({ocpus} OCPU / {memory} GB)\n"
        f"Region:            {region}\n"
        f"Availability AD:   {instance.availability_domain}\n"
        f"Public IP:         {ip}\n"
        f"Boot volume:       {env('OCI_BOOT_VOLUME_GBS', '100')} GB\n"
        f"Created (UTC):     {created}\n"
        f"Instance OCID:     {instance.id}\n"
        f"Console:           https://cloud.oracle.com/compute/instances/{instance.id}?region={region}\n"
    )
    if public_ip:
        body += f"\nSSH:               ssh {ssh_user}@{public_ip}\n"
    body += "\nThe capacity watcher will not create another instance.\n"
    return send_mail("[OCI] A1.Flex instance created in Riyadh", body)


def mark_notified(compute, instance) -> None:
    tags = dict(instance.freeform_tags or {})
    tags[TAG_KEY] = "notified"
    compute.update_instance(
        instance.id,
        oci.core.models.UpdateInstanceDetails(freeform_tags=tags),
    )
    logger.info("marked instance %s as notified", instance.id)


def suspend_self() -> None:
    if not truthy("SELF_SUSPEND", "true"):
        return

    namespace = env("POD_NAMESPACE", "oci-capacity-watcher")
    name = env("CRONJOB_NAME", "oci-capacity-watcher")
    sa_dir = Path("/var/run/secrets/kubernetes.io/serviceaccount")
    token_path = sa_dir / "token"
    ca_path = sa_dir / "ca.crt"
    if not token_path.exists():
        logger.info("not running in-cluster; skipping CronJob suspend")
        return

    body = json.dumps({"spec": {"suspend": True}}).encode()
    url = (
        "https://kubernetes.default.svc/apis/batch/v1/namespaces/"
        f"{namespace}/cronjobs/{name}"
    )
    request = urllib.request.Request(
        url,
        data=body,
        method="PATCH",
        headers={
            "Authorization": f"Bearer {token_path.read_text().strip()}",
            "Content-Type": "application/merge-patch+json",
        },
    )
    try:
        context = ssl.create_default_context(cafile=str(ca_path))
        with urllib.request.urlopen(request, timeout=10, context=context) as response:
            response.read()
    except Exception as exc:
        logger.error("could not suspend CronJob %s/%s: %s", namespace, name, exc)
        return
    logger.info("suspended CronJob %s/%s", namespace, name)


def find_instance(compute, compartment_id: str, display_name: str):
    instances = compute.list_instances(
        compartment_id, display_name=display_name
    ).data
    live = [
        i
        for i in instances
        if i.lifecycle_state not in ("TERMINATED", "TERMINATING")
    ]
    return live[0] if live else None


def is_capacity_error(exc: oci.exceptions.ServiceError) -> bool:
    message = (exc.message or "").lower()
    return "out of capacity" in message or "out of host capacity" in message


def main() -> int:
    cfg = oci_config()
    if cfg is None:
        return 0

    compartment_id = env("OCI_COMPARTMENT_ID", required=True)
    display_name = env("OCI_DISPLAY_NAME", "a1-free-retry")
    ocpus = int(env("OCI_OCPUS", "2"))
    memory_gbs = float(env("OCI_MEMORY_GBS", "12"))
    boot_gbs = int(env("OCI_BOOT_VOLUME_GBS", "100"))

    ssh_value = env(
        "OCI_SSH_PUBLIC_KEY",
        str(Path.home() / ".ssh" / "oci-machine.pub"),
    )
    if ssh_value.startswith("ssh-"):
        ssh_public_key = ssh_value
    else:
        ssh_path = Path(ssh_value).expanduser()
        if not ssh_path.exists():
            logger.error("SSH public key not found at %s", ssh_path)
            return 0
        ssh_public_key = ssh_path.read_text().strip()

    compute = oci.core.ComputeClient(
        cfg, retry_strategy=oci.retry.NoneRetryStrategy()
    )
    vn = oci.core.VirtualNetworkClient(cfg)
    identity = oci.identity.IdentityClient(cfg)

    try:
        existing = find_instance(compute, compartment_id, display_name)
    except oci.exceptions.ServiceError as exc:
        logger.error(
            "instance lookup failed: HTTP %s %s: %s",
            exc.status,
            exc.code,
            exc.message,
        )
        return 1

    if existing is not None:
        logger.info(
            "found existing instance %s (%s)", existing.id, existing.lifecycle_state
        )
        notified = (existing.freeform_tags or {}).get(TAG_KEY) == "notified"
        if not notified:
            ip = wait_for_public_ip(
                compute,
                vn,
                compartment_id,
                existing.id,
                int(env("OCI_EXISTING_IP_WAIT_SECONDS", "15")),
            )
            if notify(existing, ip):
                mark_notified(compute, existing)
                notified = True
        else:
            logger.debug("already notified; nothing to do")
        if notified:
            suspend_self()
        return 0

    try:
        availability_domain = pick_availability_domain(identity, cfg)
        subnet_id = pick_network(vn, compartment_id)
        image_id = pick_image(compute, compartment_id)
    except (oci.exceptions.ServiceError, RuntimeError) as exc:
        message = getattr(exc, "message", str(exc))
        logger.error("OCI lookup failed: %s", message)
        return 0

    details = oci.core.models.LaunchInstanceDetails(
        compartment_id=compartment_id,
        availability_domain=availability_domain,
        display_name=display_name,
        shape="VM.Standard.A1.Flex",
        shape_config=oci.core.models.LaunchInstanceShapeConfigDetails(
            ocpus=ocpus, memory_in_gbs=memory_gbs
        ),
        source_details=oci.core.models.InstanceSourceViaImageDetails(
            image_id=image_id, boot_volume_size_in_gbs=boot_gbs
        ),
        create_vnic_details=oci.core.models.CreateVnicDetails(
            subnet_id=subnet_id,
            assign_public_ip=True,
            display_name=f"{display_name}-vnic",
        ),
        metadata={"ssh_authorized_keys": ssh_public_key},
        freeform_tags={TAG_KEY: "created"},
    )

    logger.info(
        "attempting launch: shape=VM.Standard.A1.Flex %s OCPU/%s GB, AD=%s, image=%s",
        ocpus,
        memory_gbs,
        availability_domain,
        image_id,
    )
    try:
        response = compute.launch_instance(details)
    except oci.exceptions.ServiceError as exc:
        if is_capacity_error(exc):
            logger.info("no capacity yet (HTTP %s): %s", exc.status, exc.message)
            return 0
        if exc.status == 429 or (exc.code or "") in (
            "TooManyRequests",
            "LimitExceeded",
        ):
            logger.info(
                "OCI rate/limit response (HTTP %s %s): %s",
                exc.status,
                exc.code,
                exc.message,
            )
            return 0
        logger.error(
            "launch failed: HTTP %s %s: %s", exc.status, exc.code, exc.message
        )
        return 1
    except oci.exceptions.RequestException as exc:
        logger.info("transient request error, will retry: %s", exc)
        return 0

    instance = response.data
    logger.info("INSTANCE CREATED: %s", instance.id)
    ip = wait_for_public_ip(
        compute,
        vn,
        compartment_id,
        instance.id,
        int(env("OCI_PUBLIC_IP_WAIT_SECONDS", "90")),
    )
    if notify(instance, ip):
        mark_notified(compute, instance)
        suspend_self()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception as exc:
        logger.exception("unexpected failure: %s", exc)
        sys.exit(1)
