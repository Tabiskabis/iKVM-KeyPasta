#!/bin/bash
# iKVM-KeyPasta, Linux: removes what install.sh installed (both kinds, --user and --system), the
# same as: bash install.sh --remove
#
#   bash uninstall.sh

exec bash "$(dirname "$0")/install.sh" --remove
