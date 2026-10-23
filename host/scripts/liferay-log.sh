#!/usr/bin/env bash
#
# Prints this instance's Liferay log, whichever runtime it uses, so the same command works everywhere:
#
#   sudo /opt/liferay-ec2/scripts/liferay-log.sh | grep 'Server startup'
#   sudo /opt/liferay-ec2/scripts/liferay-log.sh -f        (follow)

# shellcheck source=common.sh
source "$(dirname "$0")/common.sh"

# The Tomcat runtime's service runs "catalina.sh run", which logs to systemd's journal rather
# than tomcat/logs/catalina.out. Liferay also writes /opt/liferay/logs/liferay.<date>.log.
if [ "${RUNTIME}" = "docker" ]; then
	docker logs "$@" liferay 2>&1
elif [ "${1:-}" = "-f" ]; then
	journalctl -u liferay -o cat --no-pager -n 200 -f
else
	journalctl -u liferay -o cat --no-pager
fi
