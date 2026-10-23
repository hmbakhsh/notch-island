# just install     build Island.app into ~/Applications, link `notch`, start at login
# just uninstall   undo all of that (keeps your history in ~/.local/state/notch)
# just run         run a debug build in the foreground
# Releases: ./release.sh X.Y.Z (CI builds it; see install.sh for installing one)

default:
    @just --list

build:
    swift build -c release

# Source builds are versioned dev-…, so they never update themselves from releases.
app:
    VERSION="dev-$(git describe --tags --always --dirty)" ./scripts/build.sh

install: app
    FROM=build/Island.app ./install.sh

uninstall:
    ./install.sh --uninstall

run:
    swift run Island

# Regenerate docs/screenshots from demo data
screenshots:
    ./scripts/screenshots.sh

# Render docs/screenshots/hero.png from docs/hero/hero.html (needs Google Chrome)
hero:
    "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" --headless=new --disable-gpu \
      --hide-scrollbars --allow-file-access-from-files --force-device-scale-factor=2 \
      --window-size=1280,720 --screenshot=docs/screenshots/hero.png "file://$PWD/docs/hero/hero.html" 2>/dev/null

clean:
    rm -rf .build build
