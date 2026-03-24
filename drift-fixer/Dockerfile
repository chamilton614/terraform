###############################################################################
# Terraform Drift Fixer — Multi-stage Build
#
# Includes: Terraform, Azure CLI, Python 3, jq, bash
#
# Build:
#   docker build -t drift-fixer:latest .
#
# Run:
#   docker run -it --rm \
#     -v $(pwd)/my-terraform-project:/workspace \
#     -v $HOME/.azure:/root/.azure \
#     drift-fixer:latest --dir /workspace
###############################################################################

# ═══════════════════════════════════════════════════════════════════════════════
# Stage 1: Download and verify Terraform binary
# ═══════════════════════════════════════════════════════════════════════════════
FROM alpine:3.20 AS terraform-downloader

ARG TERRAFORM_VERSION=1.9.5
ARG TARGETARCH

RUN apk add --no-cache \
        curl \
        unzip \
        gnupg

# Download Terraform
RUN ARCH=$(case "${TARGETARCH}" in \
        "amd64") echo "amd64" ;; \
        "arm64") echo "arm64" ;; \
        *)       echo "amd64" ;; \
    esac) && \
    curl -fsSL -o terraform.zip \
        "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_linux_${ARCH}.zip" && \
    curl -fsSL -o terraform_SHA256SUMS \
        "https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}/terraform_${TERRAFORM_VERSION}_SHA256SUMS" && \
    # Verify checksum
    grep "terraform_${TERRAFORM_VERSION}_linux_${ARCH}.zip" terraform_SHA256SUMS | sha256sum -c - && \
    unzip terraform.zip -d /usr/local/bin/ && \
    chmod +x /usr/local/bin/terraform && \
    rm -f terraform.zip terraform_SHA256SUMS

# ═══════════════════════════════════════════════════════════════════════════════
# Stage 2: Main runtime image
# ═══════════════════════════════════════════════════════════════════════════════
FROM python:3.12-slim-bookworm AS runtime

# ── Metadata ─────────────────────────────────────────────────────────────────
LABEL maintainer="drift-fixer"
LABEL description="Terraform Drift Detection & State Fix Tool for Azure"
LABEL version="1.0.0"

# ── Build arguments ──────────────────────────────────────────────────────────
ARG TERRAFORM_VERSION=1.9.5
ARG AZURE_CLI_VERSION=2.64.0

# ── Environment ──────────────────────────────────────────────────────────────
ENV DEBIAN_FRONTEND=noninteractive \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    # Terraform behaviour
    TF_IN_AUTOMATION=1 \
    TF_CLI_ARGS_plan="-no-color" \
    TF_INPUT=0 \
    # Tool paths
    DRIFT_FIXER_HOME=/opt/drift-fixer \
    WORKSPACE=/workspace \
    # Azure CLI
    AZURE_CONFIG_DIR=/root/.azure

# ── Install system dependencies ──────────────────────────────────────────────
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        # Core utilities
        bash \
        coreutils \
        findutils \
        grep \
        sed \
        gawk \
        # Needed by Azure CLI
        ca-certificates \
        curl \
        apt-transport-https \
        lsb-release \
        gnupg \
        # JSON processing
        jq \
        # Git (for terraform modules that pull from git)
        git \
        # SSH client (for private git modules)
        openssh-client \
        # Useful debugging tools
        less \
        vim-tiny \
        dnsutils \
        iputils-ping \
        # Column command for formatting
        bsdmainutils \
    && rm -rf /var/lib/apt/lists/*

# ── Install Azure CLI ───────────────────────────────────────────────────────
# Method: Microsoft's official package repository
RUN mkdir -p /etc/apt/keyrings && \
    curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | \
        gpg --dearmor -o /etc/apt/keyrings/microsoft.gpg && \
    chmod go+r /etc/apt/keyrings/microsoft.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] \
        https://packages.microsoft.com/repos/azure-cli/ \
        $(lsb_release -cs) main" | \
        tee /etc/apt/sources.list.d/azure-cli.list > /dev/null && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        azure-cli=${AZURE_CLI_VERSION}-1~bookworm && \
    # Clean up
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* && \
    # Trim Azure CLI to reduce image size
    az extension add --name account 2>/dev/null || true && \
    # Verify
    az version

# ── Copy Terraform from builder stage ───────────────────────────────────────
COPY --from=terraform-downloader /usr/local/bin/terraform /usr/local/bin/terraform

# Verify Terraform
RUN terraform version

# ── Install Python dependencies ─────────────────────────────────────────────
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt && \
    rm -f /tmp/requirements.txt

# ── Copy drift-fixer scripts ────────────────────────────────────────────────
RUN mkdir -p ${DRIFT_FIXER_HOME}/scripts

COPY scripts/drift_fixer.sh      ${DRIFT_FIXER_HOME}/scripts/drift_fixer.sh
COPY scripts/parse_drift.py      ${DRIFT_FIXER_HOME}/scripts/parse_drift.py
COPY scripts/azure_id_lookup.sh  ${DRIFT_FIXER_HOME}/scripts/azure_id_lookup.sh

# Set permissions
RUN chmod +x ${DRIFT_FIXER_HOME}/scripts/*.sh && \
    chmod +x ${DRIFT_FIXER_HOME}/scripts/*.py

# ── Symlink scripts into PATH ───────────────────────────────────────────────
RUN ln -sf ${DRIFT_FIXER_HOME}/scripts/drift_fixer.sh     /usr/local/bin/drift-fixer && \
    ln -sf ${DRIFT_FIXER_HOME}/scripts/azure_id_lookup.sh  /usr/local/bin/az-lookup && \
    ln -sf ${DRIFT_FIXER_HOME}/scripts/parse_drift.py      /usr/local/bin/parse-drift

# ── Copy entrypoint ─────────────────────────────────────────────────────────
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# ── Create workspace and cache directories ───────────────────────────────────
RUN mkdir -p ${WORKSPACE} \
             /root/.terraform.d/plugin-cache \
             /root/.azure \
             /tmp/drift-fixer

# ── Terraform provider cache (reduces re-downloads) ─────────────────────────
ENV TF_PLUGIN_CACHE_DIR=/root/.terraform.d/plugin-cache

# ── Healthcheck ──────────────────────────────────────────────────────────────
HEALTHCHECK --interval=60s --timeout=10s --retries=3 \
    CMD terraform version && az version --output none && python3 --version

# ── Working directory ────────────────────────────────────────────────────────
WORKDIR ${WORKSPACE}

# ── Default entrypoint & command ─────────────────────────────────────────────
ENTRYPOINT ["/entrypoint.sh"]
CMD ["--help"]