#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")"

needs_build=0
if [[ ! -f dist/src/index.js ]]; then
	needs_build=1
else
	while IFS= read -r -d '' source_file; do
		if [[ "${source_file}" -nt dist/src/index.js ]]; then
			needs_build=1
			break
		fi
	done < <(find src -type f -name '*.ts' -print0)
fi

if [[ "${needs_build}" -eq 1 ]]; then
	pnpm run build >&2
fi

exec node dist/src/index.js
