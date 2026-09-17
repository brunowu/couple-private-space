#!/bin/zsh
set -euo pipefail
project_root="${0:A:h:h}"
cd "$project_root/Backend"
export XDG_CONFIG_HOME="$PWD/.wrangler-config"
export PATH="$PWD/node_modules/.bin:$PATH"
print '本地测试口令：local-simulator-only'
exec wrangler dev --local --ip 127.0.0.1 --port "${1:-8787}" --persist-to ".wrangler/network-${1:-8787}" --var BOOTSTRAP_TOKEN:local-simulator-only
