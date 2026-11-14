#!/bin/bash
# Copy /srv/stacks/dns to Beacon (/srv/local-dns, root-owned) and run local-dns.sh there.
# Run on dsserver as daniel:  bash /srv/stacks/dns/deploy-beacon.sh preflight|install|verify|status|test-restart|rollback
set -euo pipefail
CMD=${1:?usage: $0 preflight|install|verify|status|test-restart|rollback}
rsync -a --delete --rsync-path="sudo rsync" --exclude README.md --exclude '*.md' --exclude __pycache__/ \
      --chown=root:root --chmod=D755,F644 /srv/stacks/dns/ beacon:/srv/local-dns/
ssh beacon "sudo chmod 0755 /srv/local-dns/local-dns.sh /srv/local-dns/dnsq.py && sudo /srv/local-dns/local-dns.sh $CMD"
