mkdir -p src/core src/util docs
echo 'CONFIG_VERSION_NOTE = "see core"' > src/util/notes.py
echo 'DEFAULT_TIMEOUT = 30' > src/util/defaults.py
printf 'import os\n\nCONFIG_VERSION = "4.7.1"\nDEBUG = False\n' > src/core/settings.py
echo '# Config version is documented in src/core' > docs/README.md
for i in $(seq 1 12); do echo "x = $i" > "src/util/mod$i.py"; done
