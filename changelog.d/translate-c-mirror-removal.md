### Removed

- The Codeberg-outage escape hatch `scripts/rescue-codeberg.sh` and the release
  workflow's translate-c mirror warm-up (#121): the ziglang/translate-c GitHub
  archive is archived and does not carry the `zig-0.17.x` commits the pins now
  use, so the warm-up could only fail. Dependency fetches still retry.
