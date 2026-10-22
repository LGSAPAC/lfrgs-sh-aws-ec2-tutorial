#!/usr/bin/env bash
#
# Installs the Liferay DXP Tomcat bundle in /opt/liferay and registers the liferay systemd service.
# Run by bootstrap.sh when RUNTIME=tomcat. Skips the download if the same version is installed.

# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

RELEASE_URL="https://releases-cdn.liferay.com/dxp/${LIFERAY_VERSION}"

if [ -f "${LIFERAY_HOME}/.liferay-ec2-version" ] && [ "$(cat "${LIFERAY_HOME}/.liferay-ec2-version")" = "${LIFERAY_VERSION}" ]; then
	log "Tomcat bundle ${LIFERAY_VERSION} already installed"
else
	log "Installing Amazon Corretto 21"
	dnf install -y -q java-21-amazon-corretto-headless

	id liferay > /dev/null 2>&1 || useradd --uid "${LIFERAY_UID}" --system --create-home --home-dir /home/liferay --shell /sbin/nologin liferay

	# release.properties names the bundle; the .tar.gz sits next to the .7z it lists.
	BUNDLE_URL=$(curl -fsS "${RELEASE_URL}/release.properties" | sed -n 's/^bundle.url=//p' | sed 's/\.7z$/.tar.gz/')

	[ -n "${BUNDLE_URL}" ] || fail "No bundle.url in ${RELEASE_URL}/release.properties"

	log "Downloading ${BUNDLE_URL}"

	WORK=$(mktemp -d)
	curl -fsS -o "${WORK}/bundle.tar.gz" "${BUNDLE_URL}"
	echo "$(curl -fsS "${BUNDLE_URL}.sha512")  ${WORK}/bundle.tar.gz" | sha512sum -c -

	log "Extracting into ${LIFERAY_HOME}"
	mkdir -p "${LIFERAY_HOME}"
	tar -xzf "${WORK}/bundle.tar.gz" -C "${LIFERAY_HOME}" --strip-components=1
	rm -rf "${WORK}"

	# The Tomcat folder is versioned (tomcat-10.1.x); give it a stable name for the service.
	TOMCAT_DIR=$(find "${LIFERAY_HOME}" -maxdepth 1 -type d -name 'tomcat*' | head -1)
	[ -n "${TOMCAT_DIR}" ] || fail "No tomcat folder in the bundle"
	[ "${TOMCAT_DIR}" = "${LIFERAY_HOME}/tomcat" ] || ln -sfn "${TOMCAT_DIR}" "${LIFERAY_HOME}/tomcat"

	# The bundle's setenv.sh sets its own -Xmx; append ours so it wins.
	# shellcheck disable=SC2016 # expanded by Tomcat at startup, not here
	echo 'CATALINA_OPTS="${CATALINA_OPTS} ${LIFERAY_EC2_JVM_OPTS}"' >> "${LIFERAY_HOME}/tomcat/bin/setenv.sh"

	echo "${LIFERAY_VERSION}" > "${LIFERAY_HOME}/.liferay-ec2-version"
fi

# Documents and Media on EFS (high availability) or a local folder (single instance).
mkdir -p "${LIFERAY_HOME}/data"
if [ "${DOCLIB_DIR}" != "${LIFERAY_HOME}/data/document_library" ]; then
	rm -rf "${LIFERAY_HOME}/data/document_library"
	ln -sfn "${DOCLIB_DIR}" "${LIFERAY_HOME}/data/document_library"
fi

chown -R liferay:liferay "${LIFERAY_HOME}"

install -m 644 "${LIFERAY_EC2_DIR}/systemd/liferay.service" /etc/systemd/system/liferay.service
systemctl daemon-reload
systemctl enable liferay

log "Tomcat bundle ready: $(cat "${LIFERAY_HOME}/.liferay-ec2-version")"
