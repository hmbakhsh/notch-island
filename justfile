# just install     build Island.app into ~/Applications, link `notch`, start at login
# just uninstall   undo all of that (keeps your history in ~/.local/state/notch)
# just run         run a debug build in the foreground

app_dir := env("APP_DIR", home_directory() / "Applications")
bin_dir := env("BIN_DIR", home_directory() / ".local/bin")
label := "dev.notchisland.island"
agent := home_directory() / "Library/LaunchAgents" / label + ".plist"
app := "build/Island.app"

default:
    @just --list

build:
    swift build -c release

app: build
    rm -rf {{app}}
    mkdir -p {{app}}/Contents/MacOS
    cp .build/release/Island {{app}}/Contents/MacOS/Island
    cp Resources/Info.plist {{app}}/Contents/Info.plist
    # Ad-hoc signed, but matched by bundle id rather than build hash, so macOS
    # keeps the calendar and Spotify permissions across rebuilds.
    codesign --force --sign - -r='designated => identifier "dev.notchisland.Island"' {{app}}

install: app
    -launchctl bootout gui/$(id -u)/{{label}} 2>/dev/null
    -pkill -x Island
    mkdir -p "{{app_dir}}" "{{bin_dir}}" "$(dirname '{{agent}}')"
    rm -rf "{{app_dir}}/Island.app"
    cp -R {{app}} "{{app_dir}}/Island.app"
    ln -sf "{{app_dir}}/Island.app/Contents/MacOS/Island" "{{bin_dir}}/notch"
    sed "s|@APP@|{{app_dir}}/Island.app|" Resources/launchagent.plist > "{{agent}}"
    launchctl bootstrap gui/$(id -u) "{{agent}}"
    @echo 'Installed. Try: notch "Hello" -b "from the notch" -i hand.wave.fill -c yellow'

uninstall:
    -launchctl bootout gui/$(id -u)/{{label}} 2>/dev/null
    -pkill -x Island
    rm -rf "{{app_dir}}/Island.app" "{{agent}}" "{{bin_dir}}/notch"

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
