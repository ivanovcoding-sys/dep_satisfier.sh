# dep_satisfier.sh
A standalone Bash utility for Debian/Ubuntu-based systems that walks the full
dependency tree of an `apt` package — resolving virtual packages, skipping
already-installed dependencies, and installing everything that's missing in
the correct order.



## Usage

\```bash
git clone https://github.com/ivanovcoding-sys/dep_satisfier.sh.git
sudo ./dep_satisfier.sh [OPTIONS] <package-name>

Options:
  -d, --dry-run     Show what would be installed without installing anything
  -v, --verbose     Print every dependency as it is resolved
  -l, --log FILE    Log file path (default: /var/log/dep_satisfier.log)
  -h, --help        Show this help message

# Examples
sudo ./dep_satisfier.sh ffmpeg
sudo ./dep_satisfier.sh --dry-run nginx
sudo ./dep_satisfier.sh --verbose --log ~/my.log curl
\```

## Requirements

- Debian/Ubuntu-based system with `apt-get` and `apt-cache`
- Bash 4+ (uses associative arrays)
- Root privileges for actual installs (not required for `--dry-run`)
