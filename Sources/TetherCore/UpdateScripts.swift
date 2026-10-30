import Foundation

/// The shell scripts that update Tether from its source: a release's source is fetched into a
/// private temporary folder and built there (while Tether runs), then — once Tether has quit —
/// installed with `make install` over the copy that ran, and opened again if asked.
///
/// Building needs Apple's command line tools (`swift`, `make`); without them the update stays a
/// link to the release page. Nothing is written outside the work folder until the install step.
public enum UpdateScripts {
    /// `$1` = release tag (`v1.2.3`), `$2` = work folder, `$3` = repository URL (https://github.com/…),
    /// `$4` = the version expected in the built app, `$5` = the source already downloaded (a
    /// `.tar.gz` GitHub made of the tag; empty: downloaded here with curl). Prints the built app's
    /// path on success. Exit 2: refused arguments, 3: no build tools, 4: the build made no app of
    /// that version.
    public static let fetchAndBuild = #"""
set -eu
export LC_ALL=C
tag=$1 work=$2 repo=$3 want=$4 tarball=${5:-}
case $repo in https://github.com/*) ;; *) echo "Not a GitHub repository: $repo" >&2; exit 2 ;; esac
case $tag in *[!A-Za-z0-9._-]*|'') echo "Unexpected release tag: $tag" >&2; exit 2 ;; esac
if [ -z "${TETHER_UPDATE_SKIP_TOOLS_CHECK:-}" ]; then
  xcode-select -p >/dev/null 2>&1 || { echo "Apple's command line tools are not installed (xcode-select --install)." >&2; exit 3; }
fi
command -v swift >/dev/null 2>&1 || { echo "swift was not found." >&2; exit 3; }
command -v make >/dev/null 2>&1 || { echo "make was not found." >&2; exit 3; }
mkdir -p "$work"
cd "$work"
rm -rf src
mkdir src
if [ -z "$tarball" ]; then
  echo "Downloading $tag"
  tarball=$work/source.tar.gz
  curl -fsSL --retry 2 --max-time 600 "$repo/archive/refs/tags/$tag.tar.gz" -o "$tarball"
fi
echo "Unpacking $tag"
tar -xzf "$tarball" -C src --strip-components 1
rm -f "$tarball"
cd src
echo "Building $tag"
# Stopped (Cancel, Tether quitting): the whole build stops, not only this shell — it runs in a
# process group of its own (job control), and the group is ended.
set -m
make app &
build=$!
set +m
trap 'kill -TERM -- "-$build" 2>/dev/null; kill -TERM "$build" 2>/dev/null; exit 143' TERM INT HUP
wait "$build"
trap - TERM INT HUP
plist=dist/Tether.app/Contents/Info.plist
[ -f "$plist" ] || { echo "The build made no app." >&2; exit 4; }
got=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$plist" 2>/dev/null || sed -n '/CFBundleShortVersionString/{n;s/.*<string>\(.*\)<\/string>.*/\1/p;}' "$plist")
[ "$got" = "$want" ] || { echo "The built app is version $got, not $want." >&2; exit 4; }
echo "Built $work/src/dist/Tether.app"
"""#

    /// `$1` = process id of the Tether that is quitting, `$2` = the built source folder, `$3` = the
    /// folder Tether.app is installed in, `$4` = 1 to open Tether again, `$5` = the work folder
    /// (removed after a successful install), `$6` = log file. Waits (at most 2 minutes) for that
    /// Tether to end, so a running copy is never replaced, then installs the app built and checked
    /// before (`make install-built`: copied next to the old one and swapped in, nothing rebuilt).
    public static let install = #"""
# Outlives the Tether that started it, whatever happens to that one's terminal or process group.
trap '' HUP INT TERM
pid=$1 src=$2 dest=$3 reopen=$4 work=$5 log=$6
i=0
while kill -0 "$pid" 2>/dev/null; do
  i=$((i + 1)); [ "$i" -gt 240 ] && { echo "Tether did not quit; nothing installed." >>"$log"; exit 1; }
  sleep 0.5
done
if [ -d "$src/dist/Tether.app" ] && (cd "$src" && make install-built INSTALL_DIR="$dest") >>"$log" 2>&1; then
  echo "Installed into $dest" >>"$log"
  case $work in */tether-update-*) rm -rf "$work" ;; esac
  ok=1
else
  echo "The install did not work; the installed Tether was left as it was." >>"$log"
  ok=0
fi
[ "$reopen" = 1 ] && [ -d "$dest/Tether.app" ] && open "$dest/Tether.app"
[ "$ok" = 1 ]
"""#
}

/// How far an update's build is, from its log: SwiftPM's `[n/m]` steps (compiling, linking) for
/// the app, then signing and packing. Never goes backwards.
public struct UpdateBuildProgress: Sendable {
    public private(set) var progress: Double?
    public private(set) var step = "Preparing the build…"
    private var partial = ""
    private var appDone = false

    public init() {}

    public mutating func read(_ text: String) {
        let lines = (partial + text).components(separatedBy: "\n")
        partial = lines.last ?? ""
        for line in lines.dropLast() { take(line.trimmingCharacters(in: .whitespaces)) }
    }

    private mutating func take(_ line: String) {
        if line.hasPrefix("Unpacking") {
            step = "Unpacking the source…"
        } else if line.hasPrefix("Building v") || line.hasPrefix("Building ") && line.count < 40 && !line.contains("for ") {
            step = "Building…"
            progress = progress ?? 0
        } else if line.hasPrefix("["), let close = line.firstIndex(of: "]"), !appDone {
            let parts = line[line.index(after: line.startIndex)..<close].split(separator: "/")
            if parts.count == 2, let n = Double(parts[0]), let m = Double(parts[1]), m > 0 {
                // The app's own build is most of the time; the rest is the askpass helper and signing.
                let f = min(n / m, 1) * 0.9
                if f > (progress ?? 0) { progress = f }
                let what = line[line.index(after: close)...].trimmingCharacters(in: .whitespaces)
                step = what.hasPrefix("Compiling") ? "Compiling…" : what.hasPrefix("Linking") ? "Linking…" : step == "Building…" ? step : "Building…"
            }
        } else if line.contains("Build of product 'Tether' complete") || line.hasPrefix("Build complete") {
            appDone = true
            progress = max(progress ?? 0, 0.9)
            step = "Finishing the app…"
        } else if line.hasPrefix("Built ") {
            progress = 1
            step = "Built."
        }
    }
}
