/**
 * The newest app build, which every installed app compares itself against.
 *
 * Bump `build` (the number after `+` in pubspec.yaml's `version`; it jumped
 * to 2002 to pass the 2001 of an earlier split-per-ABI arm64 APK) and
 * `version` whenever a new APK is published as a GitHub release; the app then
 * shows "Update available" to everyone on an older build.
 *
 * The URL always points at the latest GitHub release's `GeoGuard.apk`, so it
 * never has to change as long as each release attaches a file with that name.
 */
export const LATEST_RELEASE = {
  build: 2003,
  version: '1.0.2',
  url: 'https://github.com/ShUbHaMHiReMaT/veripic_flutter_app/releases/latest/download/GeoGuard.apk',
  notes: 'Check a photo straight from the Photos tab, and untouched photos no longer read as edited.',
};

/** How long one answer about the download link is reused. */
const CHECK_TTL_MS = 10 * 60_000;

let lastCheck = { at: 0, ok: false };

/**
 * Whether the advertised APK can actually be downloaded.
 *
 * The banner sends people straight to a GitHub release asset. Until a release
 * carrying `GeoGuard.apk` has been published, that link is a 404 and the user
 * lands on an empty page — so the update is offered only once the file is
 * really there. GitHub answers a present asset with a redirect to its storage.
 */
export async function releaseAvailable(fetchImpl = fetch, now = Date.now()) {
  if (lastCheck.at && now - lastCheck.at < CHECK_TTL_MS) return lastCheck.ok;

  let ok;
  try {
    const res = await fetchImpl(LATEST_RELEASE.url, {
      method: 'HEAD',
      redirect: 'manual',
    });
    ok = res.status >= 200 && res.status < 400;
  } catch {
    // GitHub unreachable from here says nothing about the file; keep the
    // last answer rather than flapping the banner.
    ok = lastCheck.ok;
  }

  lastCheck = { at: now, ok };
  return ok;
}

/** What `/app/latest` returns: no newer build until the file exists. */
export async function latestRelease(fetchImpl = fetch, now = Date.now()) {
  return (await releaseAvailable(fetchImpl, now))
    ? LATEST_RELEASE
    : { ...LATEST_RELEASE, build: 0 };
}

/** Test hook — forgets the cached answer. */
export function resetReleaseCheck() {
  lastCheck = { at: 0, ok: false };
}
