#!/usr/bin/env bash
#
# Prints this instance's Liferay log, whichever runtime it uses, so the same command works everywhere:
#
#   sudo /opt/liferay-ec2/scripts/liferay-log.sh | grep 'Server startup'
#   sudo /opt/liferay-ec2/scripts/liferay-log.sh -f        (follow)

# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

if [ "${RUNTIME}" = "docker" ]; then
	docker logs "$@" liferay 2>&1
elif [ "${1:-}" = "-f" ]; then
	tail -n 200 -F "${LIFERAY_HOME}/tomcat/logs/catalina.out"
else
	cat "${LIFERAY_HOME}/tomcat/logs/catalina.out"
fi
