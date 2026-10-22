#!/usr/bin/env bash
#
# Renders this instance's Liferay configuration from /etc/liferay-ec2/host.env and SSM Parameter Store:
#
#   /opt/liferay-ec2/runtime/files/portal-ext.properties
#   /opt/liferay-ec2/runtime/files/osgi/configs/...ElasticsearchConfiguration.config
#   /opt/liferay-ec2/runtime/files/jgroups/*.xml                (high availability only)
#   /opt/liferay-ec2/runtime/files/deploy/license.xml           (from S3, if uploaded)
#   /opt/liferay-ec2/docker/.env                                (Docker Compose settings)
#   /opt/liferay-ec2/runtime/tomcat.env                         (Tomcat runtime only)
#
# The Docker runtime mounts runtime/files at /etc/liferay/mount/files; the Tomcat runtime copies it
# into /opt/liferay. Safe to run again: it rewrites every file. Restart Liferay to apply changes.

# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

umask 077

mkdir -p "${FILES_DIR}/osgi/configs" "${FILES_DIR}/deploy"

# The Tomcat runtime's liferay user reads runtime/files; everything else in runtime/ stays root-only.
chmod 755 "${RUNTIME_DIR}"

DB_PASSWORD=$(get_secret db/password)
ADMIN_PASSWORD=$(get_secret liferay/admin-password)
PRIVATE_IP=$(imds local-ipv4)
JDBC_URL="jdbc:postgresql://${DB_HOST}:5432/${DB_NAME}"

log "Rendering configuration for ${STACK} (${MODE}, ${ROLE}, ${RUNTIME}) on ${PRIVATE_IP}"

if is_liferay_node; then
	{
		echo "# Rendered by ${LIFERAY_EC2_DIR}/scripts/render-config.sh. Do not edit: change"
		echo "# /etc/liferay-ec2/host.env or the template, then run render-config.sh again."
		echo
		echo "jdbc.default.driverClassName=org.postgresql.Driver"
		echo "jdbc.default.url=${JDBC_URL}"
		echo "jdbc.default.username=${DB_USER}"
		echo "jdbc.default.password=${DB_PASSWORD}"
		echo
		echo "setup.wizard.enabled=false"
		echo "default.admin.password=${ADMIN_PASSWORD}"
		echo
		echo "# Behind the Application Load Balancer"
		echo "web.server.forwarded.host.enabled=true"
		echo "web.server.forwarded.protocol.enabled=true"

		if [ "${HTTPS}" = "true" ]; then
			echo "web.server.protocol=https"
		fi

		if [ -n "${VIRTUAL_HOST}" ]; then
			echo "company.default.virtual.host.name=${VIRTUAL_HOST}"
		fi

		if [ "${MODE}" = "ha" ]; then
			echo
			echo "# Cluster Link over TCP unicast. AWS VPCs have no multicast, so nodes find"
			echo "# each other through a JGroups table in the shared PostgreSQL database."
			echo "cluster.link.enabled=true"
			echo "cluster.link.autodetect.address=${DB_HOST}:5432"
			echo "cluster.link.channel.properties.control=${LIFERAY_HOME}/jgroups/control.xml"
			echo "cluster.link.channel.properties.transport.0=${LIFERAY_HOME}/jgroups/transport.xml"
		fi

		echo
		echo "# Settings shared by every node, from the sample workspace's configs/ec2 (if deployed)"
		echo "include-and-override=\${liferay.home}/portal-workspace.properties"
	} > "${FILES_DIR}/portal-ext.properties"

	cat > "${FILES_DIR}/osgi/configs/com.liferay.portal.search.elasticsearch8.configuration.ElasticsearchConfiguration.config" <<CONFIG
authenticationEnabled=B"false"
httpSSLEnabled=B"false"
networkHostAddresses=["${ES_URL}"]
operationMode="REMOTE"
productionModeEnabled=B"true"
CONFIG

	if [ "${MODE}" = "ha" ]; then
		mkdir -p "${FILES_DIR}/jgroups"

		for CHANNEL in control:7800 transport:7801; do
			NAME="${CHANNEL%%:*}"
			PORT="${CHANNEL##*:}"

			sed \
				-e "s|@BIND_ADDR@|${PRIVATE_IP}|g" \
				-e "s|@BIND_PORT@|${PORT}|g" \
				-e "s|@JDBC_URL@|${JDBC_URL}|g" \
				-e "s|@DB_USER@|${DB_USER}|g" \
				-e "s|@DB_PASSWORD@|${DB_PASSWORD}|g" \
				"${LIFERAY_EC2_DIR}/config/jgroups-tcp-jdbc-ping.xml" > "${FILES_DIR}/jgroups/${NAME}.xml"
		done
	fi

	if aws s3 cp "s3://${BUCKET}/license/license.xml" "${FILES_DIR}/deploy/license.xml" --only-show-errors; then
		log "License copied from s3://${BUCKET}/license/license.xml"
	else
		rm -f "${FILES_DIR}/deploy/license.xml"
		log "WARNING: no license at s3://${BUCKET}/license/license.xml. Liferay will not become ready without one."
	fi

	chown -R "${LIFERAY_UID}:${LIFERAY_UID}" "${FILES_DIR}"
fi

PROFILES=()

if is_liferay_node && [ "${RUNTIME}" = "docker" ]; then
	PROFILES+=(liferay)
fi

if [ "${MODE}" = "single" ]; then
	PROFILES+=(db search)
fi

if [ "${ROLE}" = "search" ]; then
	PROFILES+=(search)
fi

ES_NETWORK_HOST=127.0.0.1

if [ "${ROLE}" = "search" ]; then
	ES_NETWORK_HOST=0.0.0.0
fi

cat > "${COMPOSE_DIR}/.env" <<ENV
# Rendered by render-config.sh
COMPOSE_PROFILES=$(IFS=,; echo "${PROFILES[*]}")
LIFERAY_IMAGE=$(current_liferay_image)
LIFERAY_JVM_OPTS=-Xms${LIFERAY_HEAP} -Xmx${LIFERAY_HEAP}
LIFERAY_DOCLIB_DIR=${DOCLIB_DIR}
DB_NAME=${DB_NAME}
DB_USER=${DB_USER}
DB_PASSWORD=${DB_PASSWORD}
ES_VERSION=${ES_VERSION}
ES_HEAP=${ES_HEAP}
ES_NETWORK_HOST=${ES_NETWORK_HOST}
ENV

if is_liferay_node && [ "${RUNTIME}" = "tomcat" ]; then
	cat > "${RUNTIME_DIR}/tomcat.env" <<ENV
JAVA_HOME=/usr/lib/jvm/java-21-amazon-corretto
# Appended to CATALINA_OPTS at the end of tomcat/bin/setenv.sh, so it overrides the bundle's -Xmx.
LIFERAY_EC2_JVM_OPTS=-Xms${LIFERAY_HEAP} -Xmx${LIFERAY_HEAP}
ENV
fi

log "Configuration rendered (profiles: ${PROFILES[*]:-none})"
