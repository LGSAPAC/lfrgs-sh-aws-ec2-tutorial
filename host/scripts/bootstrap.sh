#!/usr/bin/env bash
#
# Prepares this instance and starts its part of the Liferay stack. The EC2 user data runs it on
# first boot (output in /var/log/liferay-ec2-bootstrap.log); it is safe to run again, for
# example after uploading the license or changing host.env:
#
#   sudo /opt/liferay-ec2/scripts/bootstrap.sh
#
# What it does depends on host.env:
#
#   ROLE=liferay  RUNTIME=docker   Docker + Compose, Liferay container (plus db and search in MODE=single)
#   ROLE=liferay  RUNTIME=tomcat   Docker + Compose for db and search (MODE=single), Tomcat bundle as a service
#   ROLE=search                    Docker + Compose, Elasticsearch only (MODE=ha)

# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

COMPOSE_VERSION=v5.6.1

log "Bootstrapping ${STACK}: mode=${MODE} role=${ROLE} runtime=${RUNTIME}"

#
# 1. Packages: Docker, the Compose plugin, and EFS utilities for high-availability Liferay nodes.
#

dnf install -y -q docker jq unzip

if [ "${MODE}" = "ha" ] && is_liferay_node; then
	dnf install -y -q amazon-efs-utils
fi

# Tomcat runtime: Java and the liferay user first, so the config and folders below get the right owner.
if is_liferay_node && [ "${RUNTIME}" = "tomcat" ]; then
	dnf install -y -q java-21-amazon-corretto-headless
	getent group liferay > /dev/null || groupadd --gid "${LIFERAY_UID}" liferay
	id liferay > /dev/null 2>&1 || useradd --uid "${LIFERAY_UID}" --gid liferay --create-home --home-dir /home/liferay --shell /sbin/nologin liferay
fi

if ! docker compose version > /dev/null 2>&1; then
	log "Installing Docker Compose ${COMPOSE_VERSION}"
	mkdir -p /usr/local/lib/docker/cli-plugins
	curl -fsSL -o /usr/local/lib/docker/cli-plugins/docker-compose \
		"https://github.com/docker/compose/releases/download/${COMPOSE_VERSION}/docker-compose-linux-x86_64"
	chmod 755 /usr/local/lib/docker/cli-plugins/docker-compose
fi

systemctl enable --now docker

#
# 2. Kernel settings Elasticsearch needs.
#

if [ "${MODE}" = "single" ] || [ "${ROLE}" = "search" ]; then
	echo 'vm.max_map_count=262144' > /etc/sysctl.d/99-elasticsearch.conf
	sysctl -q -p /etc/sysctl.d/99-elasticsearch.conf
fi

#
# 3. Documents and Media storage: EFS in high availability, a local folder on a single instance.
#

if is_liferay_node; then
	if [ "${MODE}" = "ha" ]; then
		mkdir -p /mnt/efs

		if ! grep -q "${EFS_ID}" /etc/fstab; then
			echo "${EFS_ID}:/ /mnt/efs efs _netdev,tls 0 0" >> /etc/fstab
		fi

		# EFS mount targets can take a minute to resolve after the file system is created.
		for _ in $(seq 1 20); do
			mountpoint -q /mnt/efs && break
			mount /mnt/efs 2> /dev/null || sleep 15
		done

		mountpoint -q /mnt/efs || fail "Could not mount EFS ${EFS_ID} on /mnt/efs"
	fi

	mkdir -p "${DOCLIB_DIR}"
	chown "${LIFERAY_UID}:${LIFERAY_UID}" "${DOCLIB_DIR}"
fi

#
# 4. Configuration and images.
#

"${LIFERAY_EC2_DIR}/scripts/render-config.sh"

if [ "${MODE}" = "single" ] || [ "${ROLE}" = "search" ]; then
	if ! docker image inspect "liferay-elasticsearch:${ES_VERSION}" > /dev/null 2>&1; then
		log "Building liferay-elasticsearch:${ES_VERSION}"
		docker build -q -t "liferay-elasticsearch:${ES_VERSION}" --build-arg "ES_VERSION=${ES_VERSION}" "${COMPOSE_DIR}/elasticsearch"
	fi
fi

#
# 5. Start the services, dependencies first.
#

DEPENDENCIES=()

if [ "${MODE}" = "single" ]; then
	DEPENDENCIES=(postgres elasticsearch)
elif [ "${ROLE}" = "search" ]; then
	DEPENDENCIES=(elasticsearch)
fi

if [ "${#DEPENDENCIES[@]}" -gt 0 ]; then
	log "Starting ${DEPENDENCIES[*]}"
	compose up -d --wait --wait-timeout 600 "${DEPENDENCIES[@]}"
fi

if is_liferay_node; then
	# Liferay creates its search indexes at startup, so Elasticsearch must be up first.
	log "Waiting for Elasticsearch at ${ES_URL}"
	for _ in $(seq 1 80); do
		curl -fs --max-time 5 "${ES_URL}/_cluster/health" > /dev/null && break
		sleep 15
	done
	curl -fs --max-time 5 "${ES_URL}/_cluster/health" > /dev/null || fail "Elasticsearch at ${ES_URL} is not reachable"

	# In high availability only node 1 may start against an empty database: two nodes creating
	# the schema at once fails with 'duplicate key value violates unique constraint "release__pkey"'.
	# Nodes 2 and up wait until node 1 answers. Later restarts don't wait: node 1 is already up.
	if [ "${MODE}" = "ha" ] && [ "${NODE_INDEX:-1}" -gt 1 ]; then
		FIRST_NODE_IP=""

		log "Waiting for ${FIRST_NODE_NAME} to finish starting (this is node ${NODE_INDEX})"

		for _ in $(seq 1 180); do
			if [ -z "${FIRST_NODE_IP}" ] || [ "${FIRST_NODE_IP}" = "None" ]; then
				FIRST_NODE_IP=$(aws ec2 describe-instances \
					--filters "Name=tag:Name,Values=${FIRST_NODE_NAME}" "Name=instance-state-name,Values=running" \
					--query 'Reservations[0].Instances[0].PrivateIpAddress' --output text 2> /dev/null || true)
			fi

			if [ -n "${FIRST_NODE_IP}" ] && [ "${FIRST_NODE_IP}" != "None" ] && \
				[ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 -H "Host: ${FIRST_NODE_IP}" "http://${FIRST_NODE_IP}:8080/c/portal/robots")" = "200" ]; then
				log "${FIRST_NODE_NAME} (${FIRST_NODE_IP}) is up"
				break
			fi

			sleep 15
		done
	fi

	if [ "${RUNTIME}" = "docker" ]; then
		IMAGE=$(current_liferay_image)

		if [[ "${IMAGE}" == *.dkr.ecr.* ]]; then
			aws ecr get-login-password | docker login --username AWS --password-stdin "${IMAGE%%/*}"
		fi

		log "Starting Liferay container ${IMAGE}"
		compose up -d liferay
	else
		"${LIFERAY_EC2_DIR}/scripts/install-tomcat-bundle.sh"

		log "Starting Liferay Tomcat service"
		systemctl restart liferay
	fi

	"${LIFERAY_EC2_DIR}/scripts/wait-for-liferay.sh" 1800
fi

date -u +%FT%TZ > "${RUNTIME_DIR}/bootstrap.done"

log "Bootstrap finished. Check this instance with: sudo ${LIFERAY_EC2_DIR}/scripts/verify-node.sh"
